class ExecutionLedger
  class Error < StandardError; end
  class InvalidRun < Error; end
  class EventConflict < Error; end
  class OutOfOrder < Error; end

  TRANSITIONS = {
    "run.admitted" => [ "admitting", "admitted" ],
    "run.started" => [ "admitted", "running" ],
    "tool.completed" => [ "running", "running" ],
    "output.produced" => [ "running", "running" ],
    "usage.observed" => [ "running", "running" ],
    "run.completed" => [ "running", "completed" ],
    "run.failed" => [ "running", "failed" ],
    "run.timed_out" => [ "running", "timed_out" ],
    "run.canceled" => [ "running", "canceled" ],
    "run.policy_denied" => [ "running", "policy_denied" ]
  }.freeze

  def self.start!(workspace:, task:, request_key:, client: RunnerClient.new)
    ledger = new(workspace:)
    run = ledger.prepare!(task:, request_key:)
    ledger.admit!(run:, client:)
  end

  def self.ingest!(workspace:, event:)
    new(workspace:).ingest!(event:)
  end

  def initialize(workspace:)
    @workspace = workspace
  end

  def prepare!(task:, request_key:)
    task = @workspace.crew_tasks.find(task.id)
    request_key = request_key.to_s
    raise InvalidRun, "Execution request key is invalid." if request_key.blank? || request_key.bytesize > 128

    ExecutionRun.transaction do
      task.lock!
      existing = @workspace.execution_runs.find_by(request_key:)
      if existing
        raise InvalidRun, "Execution request key belongs to another task." unless existing.crew_task_id == task.id
        return existing
      end
      unless task.ready? || task.in_progress?
        raise InvalidRun, "Only ready or active tasks can run."
      end

      attempt = task.execution_runs.maximum(:attempt_number).to_i + 1
      @workspace.execution_runs.create!(
        crew_task: task,
        agent_profile: task.assigned_agent_profile,
        agent_profile_version: task.assigned_agent_profile_version,
        request_key:,
        attempt_number: attempt,
        runtime_profile_key: task.assigned_agent_profile_version.runtime_profile_key
      )
    end
  rescue ActiveRecord::RecordInvalid => error
    raise InvalidRun, error.record.errors.full_messages.to_sentence
  end

  def admit!(run:, client: RunnerClient.new)
    run = @workspace.execution_runs.find(run.id)
    run.with_lock do
      return run unless run.admitting?

      run.update!(
        admission_attempt_count: run.admission_attempt_count + 1,
        admission_attempted_at: Time.current,
        last_admission_error: nil
      )
    end

    response = client.admit!(
      task: run.crew_task,
      run_id: run.run_key,
      idempotency_key: "admit:#{run.run_key}",
      attempt: run.attempt_number
    )
    ingest!(event: response.event)
    run.reload
  rescue RunnerClient::Error => error
    record_admission_error(run, error)
    raise
  end

  def ingest!(event:)
    message = event.is_a?(RunnerProtocol::CanonicalEvent) ? event : RunnerProtocol::CanonicalEvent.new(event.to_h.deep_stringify_keys)
    attributes = message.attributes
    digest = Digest::SHA256.hexdigest(JSON.generate(canonical(attributes)))

    ExecutionRun.transaction do
      run = @workspace.execution_runs.find_by!(run_key: attributes.fetch("run_id"))
      run.lock!

      if (existing = @workspace.execution_events.find_by(event_key: attributes.fetch("event_id")))
        return replay_or_conflict(existing, digest)
      end
      sequence = attributes.fetch("sequence")
      if sequence <= run.current_sequence
        existing = run.events.find_by(sequence_number: sequence)
        return replay_or_conflict(existing, digest) if existing
        raise EventConflict, "Event sequence was already consumed."
      end
      raise OutOfOrder, "Next event must have sequence #{run.current_sequence + 1}." unless sequence == run.current_sequence + 1
      if run.current_event && message.occurred_at < run.current_event.occurred_at
        raise OutOfOrder, "Event time cannot move backwards."
      end
      raise OutOfOrder, "Event time is too far in the future." if message.occurred_at > 5.minutes.from_now

      event_record = run.events.create!(
        workspace: @workspace,
        event_key: attributes.fetch("event_id"),
        sequence_number: sequence,
        event_type: attributes.fetch("event_type"),
        occurred_at: message.occurred_at,
        data: attributes.fetch("data"),
        payload_digest: digest
      )
      updates = updates_for(run, event_record)
      run.update!(updates.merge(current_sequence: sequence, current_event: event_record))
      event_record
    end
  rescue ActiveRecord::RecordInvalid => error
    raise InvalidRun, error.record.errors.full_messages.to_sentence
  rescue ActiveRecord::RecordNotUnique
    raise EventConflict, "Event identity or sequence is already in use."
  end

  private
    def updates_for(run, event)
      from, to = TRANSITIONS.fetch(event.event_type)
      raise OutOfOrder, "Event #{event.event_type} cannot follow #{run.status}." unless run.status == from

      data = event.data
      updates = { status: to }
      case event.event_type
      when "run.admitted"
        unless data == {
          "workspace_key" => @workspace.runner_key,
          "task_key" => run.crew_task.task_key,
          "attempt" => run.attempt_number
        }
          raise EventConflict, "Admission event does not match its run."
        end
        updates[:admitted_at] = event.occurred_at
        updates[:last_admission_error] = nil
      when "run.started"
        raise EventConflict, "Start event does not match its attempt." unless data.fetch("attempt") == run.attempt_number
        updates[:started_at] = event.occurred_at
      when "output.produced"
        updates[:output] = data.fetch("text")
      when "usage.observed"
        updates[:input_units] = run.input_units + data.fetch("input_units")
        updates[:output_units] = run.output_units + data.fetch("output_units")
      when "run.completed"
        updates[:finished_at] = event.occurred_at
      when "run.failed"
        updates.merge!(failure_code: data.fetch("code"), retryable: data.fetch("retryable"), finished_at: event.occurred_at)
      when "run.timed_out", "run.canceled"
        updates.merge!(failure_code: event.event_type.delete_prefix("run."), retryable: false, finished_at: event.occurred_at)
      when "run.policy_denied"
        updates.merge!(failure_code: data.fetch("code"), retryable: false, finished_at: event.occurred_at)
      end
      updates
    end

    def replay_or_conflict(existing, digest)
      return existing if existing.payload_digest == digest

      raise EventConflict, "Event replay changed its payload."
    end

    def record_admission_error(run, error)
      return unless run&.persisted?

      run.with_lock do
        return unless run.admitting?
        run.update!(last_admission_error: admission_error_code(error), admission_attempted_at: Time.current)
      end
    end

    def admission_error_code(error)
      case error
      when RunnerClient::AmbiguousResult then "ambiguous_result"
      when RunnerClient::Unavailable then "runner_unavailable"
      when RunnerClient::AuthenticationError then "authentication_failed"
      when RunnerClient::PolicyDenied then "policy_denied"
      when RunnerClient::Conflict then "idempotency_conflict"
      when RunnerClient::MalformedResponse then "malformed_response"
      when RunnerClient::ConfigurationError then "configuration_error"
      else "runner_error"
      end
    end

    def canonical(value)
      case value
      when Hash then value.keys.sort.to_h { |key| [ key, canonical(value.fetch(key)) ] }
      when Array then value.map { |item| canonical(item) }
      else value
      end
    end
end
