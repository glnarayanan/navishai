require "test_helper"

class ExecutionLedgerTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
    approve_scripted_runtime(workspace: @workspace, membership: @owner)
    CrewConfiguration.install_defaults!(workspace: @workspace)
    @support_case = create_support_case
    @message = add_inbound_message(@support_case)
    profile = @workspace.agent_profiles.find_by!(role_key: "support_investigator")
    @task = CrewWork.create!(
      workspace: @workspace, membership: @owner, scope: @support_case, profile:,
      title: "Investigate the failure", input_context: "Use the current case and approved sources.",
      expected_output: "State the cause and cite the evidence."
    )
    @ledger = ExecutionLedger.new(workspace: @workspace)
    @run = @ledger.prepare!(task: @task, request_key: "request:one")
    @time = Time.current.change(usec: 0)
  end

  test "persists ordered events, output, usage, and terminal state" do
    ingest(1, "run.admitted", workspace_key: @workspace.runner_key, task_key: @task.task_key, attempt: 1)
    ingest(2, "run.started", adapter: "scripted", scenario: "success", attempt: 1)
    ingest(3, "tool.completed", tool: "case_read", result: "scripted")
    ingest(4, "output.produced", text: artifact_output)
    ingest(5, "usage.observed", input_units: 12, output_units: 3)
    ingest(6, "usage.observed", input_units: 8, output_units: 2)
    ingest(7, "run.completed", outcome: "completed")

    @run.reload
    assert @run.completed?
    assert_equal 7, @run.current_sequence
    assert_equal artifact_output, @run.output
    assert_equal "The reset link expired.", @run.crew_artifact.body
    assert_equal 20, @run.input_units
    assert_equal 5, @run.output_units
    assert_equal (1..7).to_a, @run.events.pluck(:sequence_number)
    assert_equal @run.events.last, @run.current_event
  end

  test "exact replay is idempotent while changed and out-of-order events fail" do
    attributes = event(1, "run.admitted", workspace_key: @workspace.runner_key, task_key: @task.task_key, attempt: 1)
    first = @ledger.ingest!(event: attributes)
    reordered = attributes.reverse_each.to_h
    assert_equal first, @ledger.ingest!(event: reordered)
    assert_equal 1, @run.events.count

    changed = attributes.deep_dup
    changed["data"]["attempt"] = 2
    assert_raises(ExecutionLedger::EventConflict) { @ledger.ingest!(event: changed) }
    assert_raises(ExecutionLedger::OutOfOrder) do
      @ledger.ingest!(event: event(3, "run.started", adapter: "scripted", scenario: "gap", attempt: 1))
    end
    assert_equal 1, @run.reload.current_sequence
  end

  test "attempts freeze policy and request keys are idempotent under the task lock" do
    same = @ledger.prepare!(task: @task, request_key: "request:one")
    second = @ledger.prepare!(task: @task, request_key: "request:two")

    assert_equal @run, same
    assert_equal 2, second.attempt_number
    assert_equal @task.assigned_agent_profile_version, second.agent_profile_version
    assert_equal @task.assigned_agent_profile_version.runtime_profile_key, second.runtime_profile_key
    assert_equal runtime_installations(:acme_scripted), second.runtime_installation
    assert_equal runtime_installations(:acme_scripted).detection_key, second.selected_runtime_detection_key
    assert_equal "scripted", second.selected_adapter_key
    assert_equal "primary", second.runtime_selection_reason
    assert_equal %w[approved_knowledge case_content customer_identity public_web_query], second.disclosed_data_classes
    assert_equal 100_000, second.max_input_units
    assert_equal 25_000, second.max_output_units

    stale_attempt = event(1, "run.admitted",
      workspace_key: @workspace.runner_key, task_key: @task.task_key, attempt: 1)
    stale_attempt["run_id"] = second.run_key
    assert_raises(ExecutionLedger::EventConflict) { @ledger.ingest!(event: stale_attempt) }
    assert_equal 0, second.reload.current_sequence

    another_case = create_support_case(subject: "Another case")
    another = CrewWork.create!(
      workspace: @workspace, membership: @owner, scope: another_case,
      profile: @task.assigned_agent_profile, title: "Another task",
      input_context: "Use another case.", expected_output: "Return another result."
    )
    assert_raises(ExecutionLedger::InvalidRun) do
      @ledger.prepare!(task: another, request_key: "request:one")
    end
  end

  test "incompatible routing leaves no partial run" do
    installation = runtime_installations(:acme_scripted)
    installation.update!(approved: false, approved_by_membership: nil, approved_by_user: nil, approved_at: nil)

    assert_no_difference -> { @workspace.execution_runs.count } do
      error = assert_raises(ExecutionLedger::InvalidRun) do
        @ledger.prepare!(task: @task, request_key: "request:blocked")
      end
      assert_includes error.message, "No compatible runtime"
    end
  end

  test "usage cannot exceed the frozen runtime budget" do
    ingest(1, "run.admitted", workspace_key: @workspace.runner_key, task_key: @task.task_key, attempt: 1)
    ingest(2, "run.started", adapter: "scripted", scenario: "budget", attempt: 1)

    assert_raises(ExecutionLedger::EventConflict) do
      ingest(3, "usage.observed", input_units: @run.max_input_units + 1, output_units: 0)
    end
    assert_equal 2, @run.reload.current_sequence
    assert_equal 0, @run.input_units
    assert_equal 2, @run.events.count
  end

  test "start event must match the frozen adapter" do
    ingest(1, "run.admitted", workspace_key: @workspace.runner_key, task_key: @task.task_key, attempt: 1)

    assert_raises(ExecutionLedger::EventConflict) do
      ingest(2, "run.started", adapter: "claude_subscription", scenario: "wrong", attempt: 1)
    end
    assert_equal 1, @run.reload.current_sequence
    assert @run.admitted?
    assert_equal 1, @run.events.count
  end

  test "admission retries reuse one run and retain ambiguous failure visibility" do
    failure_client = Object.new
    failure_client.define_singleton_method(:admit!) { |**| raise RunnerClient::AmbiguousResult, "unknown" }

    assert_raises(RunnerClient::AmbiguousResult) { @ledger.admit!(run: @run, client: failure_client) }
    assert_equal "ambiguous_result", @run.reload.last_admission_error
    assert_equal 1, @run.admission_attempt_count

    response = Data.define(:event).new(
      event(1, "run.admitted", workspace_key: @workspace.runner_key, task_key: @task.task_key, attempt: 1)
    )
    expected_task = @task
    expected_run_key = @run.run_key
    success_client = Object.new
    success_client.define_singleton_method(:admit!) do |task:, run_id:, idempotency_key:, attempt:, input_context:, **|
      unless task == expected_task && run_id == expected_run_key && idempotency_key == "admit:#{expected_run_key}" && attempt == 1
        raise "wrong task"
      end
      raise "wrong context" unless input_context == task.input_context
      response
    end
    assert_equal @run, @ledger.admit!(run: @run, client: success_client)
    assert @run.reload.admitted?
    assert_nil @run.last_admission_error
    assert_equal 2, @run.admission_attempt_count
  end

  test "terminal, tenant, time, and append-only boundaries fail closed" do
    ingest(1, "run.admitted", workspace_key: @workspace.runner_key, task_key: @task.task_key, attempt: 1)
    ingest(2, "run.started", adapter: "scripted", scenario: "failure", attempt: 1)
    ingest(3, "run.failed", code: "fixture_error", retryable: true)
    assert @run.reload.failed?
    assert_equal "fixture_error", @run.failure_code
    assert @run.retryable

    assert_raises(ExecutionLedger::OutOfOrder) do
      ingest(4, "run.completed", outcome: "completed")
    end
    assert_raises(ActiveRecord::ReadOnlyRecord) { @run.events.first.update!(data: {}) }
    assert_raises(ActiveRecord::StatementInvalid) do
      ExecutionRun.transaction(requires_new: true) { ExecutionRun.where(id: @run.id).update_all(run_key: SecureRandom.uuid) }
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      ExecutionRun.transaction(requires_new: true) { ExecutionRun.where(id: @run.id).update_all(input_context: "Changed") }
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      ExecutionRun.transaction(requires_new: true) do
        ExecutionRun.where(id: @run.id).update_all(selected_runtime_detection_key: "f" * 64)
      end
    end

    foreign = workspaces(:beta_support)
    assert_raises(ActiveRecord::RecordNotFound) do
      ExecutionLedger.ingest!(workspace: foreign, event: event(4, "run.completed", outcome: "completed"))
    end
    backwards = event(4, "run.completed", outcome: "completed")
    backwards["occurred_at"] = 1.hour.ago.iso8601
    assert_raises(ExecutionLedger::OutOfOrder) { @ledger.ingest!(event: backwards) }
  end

  test "PostgreSQL rejects an event that mutates unrelated run state" do
    ingest(1, "run.admitted", workspace_key: @workspace.runner_key, task_key: @task.task_key, attempt: 1)
    ingest(2, "run.started", adapter: "scripted", scenario: "tamper", attempt: 1)

    assert_raises(ActiveRecord::StatementInvalid) do
      ExecutionRun.transaction(requires_new: true) do
        record = @run.events.create!(
          workspace: @workspace, event_key: SecureRandom.uuid, sequence_number: 3,
          event_type: "tool.completed", occurred_at: @time + 3.seconds,
          data: { "tool" => "case_read", "result" => "scripted" }, payload_digest: "a" * 64
        )
        ExecutionRun.where(id: @run.id).update_all(
          current_sequence: 3, current_event_id: record.id, input_units: 999
        )
      end
    end
    assert_equal 2, @run.reload.current_sequence
    assert_equal 0, @run.input_units
    assert_equal 2, @run.events.count

    assert_raises(ActiveRecord::StatementInvalid) do
      ExecutionRun.transaction(requires_new: true) do
        record = ExecutionEvent.create!(
          workspace: @workspace, execution_run: @run, event_key: SecureRandom.uuid,
          sequence_number: 3, event_type: "tool.completed", occurred_at: @time + 3.seconds,
          data: {}, payload_digest: "b" * 64
        )
        ExecutionRun.where(id: @run.id).update_all(current_sequence: 3, current_event_id: record.id)
      end
    end
    assert_equal 2, @run.reload.current_sequence
    assert_equal 2, @run.events.count
  end

  private
    def artifact_output
      JSON.generate(
        schema_version: 1, kind: "investigation", body: "The reset link expired.",
        uncertainty: "The opening time is unknown.", conflicts: [], change_requests: [], review_outcome: nil,
        citations: [ {
          kind: "conversation", locator: "conversation://#{@support_case.conversation_id}/messages/#{@message.id}",
          label: "Customer report"
        } ]
      )
    end

    def ingest(sequence, type, **data)
      @ledger.ingest!(event: event(sequence, type, **data))
    end

    def event(sequence, type, **data)
      {
        "protocol_version" => "v1",
        "event_id" => SecureRandom.uuid,
        "run_id" => @run.run_key,
        "sequence" => sequence,
        "event_type" => type,
        "occurred_at" => (@time + sequence.seconds).iso8601(6),
        "data" => data.deep_stringify_keys
      }
    end
end
