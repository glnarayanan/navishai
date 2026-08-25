class CrewArtifactPublisher
  class InvalidOutput < StandardError; end
  class Conflict < InvalidOutput; end

  SCHEMA_KEYS = %w[
    schema_version kind body uncertainty citations conflicts change_requests review_outcome memory_proposals
  ].sort.freeze
  ROLE_KINDS = {
    "support_investigator" => "investigation",
    "resolution_drafter" => "draft",
    "support_reviewer" => "quality_review"
  }.freeze
  CITATION_KEYS = %w[kind label locator].sort.freeze
  CONFLICT_KEYS = %w[details severity summary].sort.freeze
  CONFLICT_SEVERITIES = %w[info warning blocking].freeze

  def self.publish!(workspace:, task:, run:, target_artifact: nil)
    new(workspace:).publish!(task:, run:, target_artifact:)
  end

  def self.supports?(run)
    ROLE_KINDS.key?(run.agent_profile.role_key)
  end

  def initialize(workspace:)
    @workspace = workspace
  end

  def publish!(task:, run:, target_artifact: nil)
    task = @workspace.crew_tasks.find(task.id)
    run = @workspace.execution_runs.find(run.id)
    raise InvalidOutput, "Run does not belong to this task." unless run.crew_task_id == task.id
    raise InvalidOutput, "Only a completed run can publish output." unless run.completed?

    digest = Digest::SHA256.hexdigest(run.output.to_s)
    payload = parse(run.output)
    kind = ROLE_KINDS.fetch(run.agent_profile.role_key) do
      raise InvalidOutput, "This specialist cannot publish a support artifact."
    end
    raise InvalidOutput, "Output kind does not match the specialist role." unless payload.fetch("kind") == kind

    CrewArtifact.transaction do
      task.lock!
      run.lock!
      if (existing = @workspace.crew_artifacts.find_by(execution_run: run))
        return existing if existing.payload_digest == digest
        raise Conflict, "This run already published different output."
      end
      latest = task.artifacts.where(artifact_kind: kind).order(version_number: :desc).first
      if latest && latest.execution_run.attempt_number >= run.attempt_number
        raise Conflict, "A newer output version already exists."
      end

      target = review_target!(task, run, kind, target_artifact)
      artifact = @workspace.crew_artifacts.create!(
        crew_task: task, execution_run: run, artifact_kind: kind,
        version_number: latest&.version_number.to_i + 1,
        supersedes_artifact: latest,
        target_artifact: target,
        body: bounded_text(payload.fetch("body"), 50.kilobytes, "Body"),
        uncertainty: bounded_text(payload.fetch("uncertainty"), 4_000, "Uncertainty"),
        review_outcome: review_outcome!(kind, payload),
        citations: citations!(task, payload.fetch("citations")),
        conflicts: conflicts!(payload.fetch("conflicts")),
        change_requests: change_requests!(kind, payload),
        payload_digest: digest
      )
      AuditEvent.record!(
        action: "crew.artifact_published", source: :runner, workspace: @workspace,
        actor_kind: :system, subject: artifact,
        metadata: { "artifact_kind" => kind, "version" => artifact.version_number }
      )
      publish_memory_proposals!(task, artifact, payload.fetch("memory_proposals"))
      artifact
    end
  rescue JSON::ParserError, TypeError, KeyError
    raise InvalidOutput, "Run output does not match artifact schema."
  rescue ActiveRecord::RecordInvalid => error
    raise InvalidOutput, error.record.errors.full_messages.to_sentence
  rescue ActiveRecord::RecordNotUnique
    raise Conflict, "Output version changed concurrently."
  end

  private
    def parse(raw)
      raise InvalidOutput, "Run output is missing." if raw.blank? || raw.bytesize > 100.kilobytes

      payload = JSON.parse(raw)
      unless payload.is_a?(Hash) && payload.keys.sort == SCHEMA_KEYS && payload.fetch("schema_version") == 1
        raise InvalidOutput, "Run output does not match artifact schema."
      end
      unless %w[citations conflicts change_requests].all? { |key| payload[key].is_a?(Array) && payload[key].size <= 20 } &&
          payload["memory_proposals"].is_a?(Array) && payload["memory_proposals"].size <= 10
        raise InvalidOutput, "Run output collections are invalid."
      end
      payload
    end

    def review_target!(task, run, kind, value)
      if kind != "quality_review"
        raise InvalidOutput, "Only a quality review can target an artifact." if value.present?
        return nil
      end
      if value.present? && value != run.input_artifact
        raise InvalidOutput, "Quality review target changed after the run started."
      end
      value ||= run.input_artifact
      raise InvalidOutput, "A quality review must target the latest draft." if value.blank?

      target = @workspace.crew_artifacts.find(value.id)
      latest = @workspace.crew_artifacts.joins(:crew_task)
        .where(artifact_kind: "draft", crew_tasks: scope_filter(task)).order(created_at: :desc, id: :desc).first
      unless target.draft? && target == latest && same_scope?(task, target.crew_task)
        raise InvalidOutput, "A quality review must target the latest draft."
      end
      target
    end

    def citations!(task, values)
      unless values.is_a?(Array) && values.size.in?(1..20)
        raise InvalidOutput, "Citations must contain between 1 and 20 entries."
      end
      values.map do |value|
        unless value.is_a?(Hash) && value.keys.sort == CITATION_KEYS
          raise InvalidOutput, "A citation does not match the schema."
        end
        kind = value.fetch("kind").to_s
        locator = bounded_text(value.fetch("locator"), 2_000, "Citation locator")
        label = bounded_text(value.fetch("label"), 200, "Citation label")
        validate_locator!(task, kind, locator)
        { "kind" => kind, "locator" => locator, "label" => label }
      end
    end

    def validate_locator!(task, kind, locator)
      case kind
      when "knowledge"
        match = locator.match(%r{\Aknowledge://sources/([0-9a-f-]{36})/versions/(\d+)\z})
        source = match && @workspace.knowledge_sources.find_by(source_key: match[1])
        version = source && source.versions.find_by(version_number: match[2].to_i)
        raise InvalidOutput, "Knowledge citation is unavailable." unless version&.citation_uri == locator
      when "conversation"
        match = locator.match(%r{\Aconversation://(\d+)/messages/(\d+)\z})
        conversation = task.support_case&.conversation
        message = match && conversation&.conversation_messages&.find_by(id: match[2])
        unless conversation && conversation.id == match[1].to_i && message
          raise InvalidOutput, "Conversation citation is unavailable."
        end
      when "case"
        raise InvalidOutput, "Case citation is unavailable." unless task.support_case && locator == "case://#{task.support_case_id}"
      when "account"
        account_id = task.account_id || task.support_case&.conversation&.contact&.account_id
        raise InvalidOutput, "Account citation is unavailable." unless account_id && locator == "account://#{account_id}"
      when "public_web"
        match = locator.match(%r{\Apublic-web://([0-9a-f-]{36})\z})
        result = match && @workspace.public_web_search_results.joins(:public_web_search)
          .find_by(citation_key: match[1], public_web_searches: { crew_task_id: task.id, status: "completed" })
        raise InvalidOutput, "Public-web citation is unavailable." unless result
      else
        raise InvalidOutput, "Citation type is not supported."
      end
    end

    def conflicts!(values)
      unless values.is_a?(Array) && values.size <= 20
        raise InvalidOutput, "Conflicts must be an array with at most 20 entries."
      end
      values.map do |value|
        unless value.is_a?(Hash) && value.keys.sort == CONFLICT_KEYS &&
            CONFLICT_SEVERITIES.include?(value.fetch("severity"))
          raise InvalidOutput, "A conflict does not match the schema."
        end
        {
          "summary" => bounded_text(value.fetch("summary"), 200, "Conflict summary"),
          "details" => bounded_text(value.fetch("details"), 2_000, "Conflict details"),
          "severity" => value.fetch("severity")
        }
      end
    end

    def review_outcome!(kind, payload)
      outcome = payload.fetch("review_outcome")
      if kind == "quality_review"
        raise InvalidOutput, "Review outcome is invalid." unless CrewArtifact::REVIEW_OUTCOMES.include?(outcome)
        has_blocker = payload.fetch("conflicts").any? { |conflict| conflict.is_a?(Hash) && conflict["severity"] == "blocking" }
        raise InvalidOutput, "A review with blocking conflicts cannot be approved." if outcome == "approved" && has_blocker
      elsif outcome.present?
        raise InvalidOutput, "Only a quality review can record an outcome."
      end
      outcome
    end

    def change_requests!(kind, payload)
      values = payload.fetch("change_requests")
      unless values.is_a?(Array) && values.size <= 20
        raise InvalidOutput, "Change requests must be an array with at most 20 entries."
      end
      if kind != "quality_review" && values.present?
        raise InvalidOutput, "Only a quality review can request changes."
      end
      if kind == "quality_review" && (payload.fetch("review_outcome") == "changes_requested") != values.present?
        raise InvalidOutput, "Change requests do not match the review outcome."
      end
      values.map { |value| bounded_text(value, 2_000, "Change request") }
    end

    def bounded_text(value, maximum, name)
      raise InvalidOutput, "#{name} must be text." unless value.is_a?(String)

      text = value.strip
      if text.blank? || text.bytesize > maximum
        raise InvalidOutput, "#{name} is required and must be at most #{maximum} bytes."
      end
      text
    end

    def publish_memory_proposals!(task, artifact, values)
      values.each do |value|
        unless value.is_a?(Hash) && value.keys.sort == %w[confidence content memory_type scope_kind topic]
          raise InvalidOutput, "A memory proposal does not match the schema."
        end
        scope = proposal_scope!(task, value.fetch("scope_kind"))
        MemoryPublication.propose!(
          workspace: @workspace, artifact:, memory_type: value.fetch("memory_type"), scope:,
          topic: bounded_text(value.fetch("topic"), 200, "Memory topic"),
          content: bounded_text(value.fetch("content"), 32_768, "Memory content"),
          confidence: value.fetch("confidence")
        )
      end
    rescue ActiveRecord::RecordInvalid, ArgumentError => error
      raise InvalidOutput, error.message
    end

    def proposal_scope!(task, kind)
      case kind
      when "support_case"
        task.support_case || raise(InvalidOutput, "Case memory is unavailable for this task.")
      when "contact"
        task.support_case&.conversation&.contact || raise(InvalidOutput, "Contact memory is unavailable for this task.")
      when "account"
        task.account || task.support_case&.conversation&.contact&.account ||
          raise(InvalidOutput, "Account memory is unavailable for this task.")
      else
        raise InvalidOutput, "Memory proposal scope is unsupported."
      end
    end

    def same_scope?(left, right)
      left.scope_kind == right.scope_kind && left.support_case_id == right.support_case_id && left.account_id == right.account_id
    end

    def scope_filter(task)
      { scope_kind: task.scope_kind, support_case_id: task.support_case_id, account_id: task.account_id }
    end
end
