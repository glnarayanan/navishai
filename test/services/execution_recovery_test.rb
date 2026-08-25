require "test_helper"

class ExecutionRecoveryTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
    approve_scripted_runtime(workspace: @workspace, membership: @owner)
    CrewConfiguration.install_defaults!(workspace: @workspace)
    @support_case = create_support_case
    @profile = @workspace.agent_profiles.find_by!(role_key: "support_investigator")
    @task = CrewWork.create!(
      workspace: @workspace, membership: @owner, scope: @support_case, profile: @profile,
      title: "Investigate the failure", input_context: "Use current case evidence.",
      expected_output: "Return a cited finding."
    )
    CrewWork.apply!(
      workspace: @workspace, membership: @owner, task: @task, command: :start,
      expected_sequence: @task.current_event.sequence_number
    )
  end

  test "requests one attributable run and keeps exact request replay idempotent" do
    client = accepting_client
    assert_difference -> { @task.execution_runs.count }, 1 do
      assert_difference -> { AuditEvent.where(action: "execution.run_requested").count }, 1 do
        @run = request_run(client:, request_key: "web:one")
      end
    end
    assert @run.admitted?
    assert_equal @owner.user, AuditEvent.find_by!(action: "execution.run_requested", subject_id: @run.id).actor

    assert_no_difference [ -> { @task.execution_runs.count }, -> { AuditEvent.where(action: "execution.run_requested").count } ] do
      assert_equal @run, request_run(client: rejecting_client, request_key: "web:one")
    end
    assert_equal 1, client.calls

    error = assert_raises(ExecutionRecovery::InvalidAction) do
      request_run(client: accepting_client, request_key: "web:two")
    end
    assert_match(/already has an active run/, error.message)
  end

  test "reconciles ambiguous admission with the same run and records the human attempt" do
    assert_raises(RunnerClient::AmbiguousResult) do
      request_run(client: rejecting_client, request_key: "web:ambiguous")
    end
    run = @task.execution_runs.find_by!(request_key: "web:ambiguous")
    assert run.admitting?
    assert_equal "ambiguous_result", run.last_admission_error

    assert_difference -> { AuditEvent.where(action: "execution.run_reconciled", subject_id: run.id).count }, 1 do
      ExecutionRecovery.reconcile!(
        workspace: @workspace, membership: @owner, task: @task, run:, client: accepting_client
      )
    end
    assert run.reload.admitted?
    assert_equal 1, @task.execution_runs.count
  end

  test "keeps a durable diagnostic when local runner configuration is unavailable" do
    assert_raises(RunnerClient::ConfigurationError) do
      ExecutionRecovery.request!(
        workspace: @workspace, membership: @owner, task: @task,
        request_key: "web:configuration"
      )
    end
    run = @task.execution_runs.find_by!(request_key: "web:configuration")
    assert run.admitting?
    assert_equal "configuration_error", run.last_admission_error
    assert AuditEvent.exists?(action: "execution.run_requested", subject_id: run.id, actor: @owner.user)
  end

  test "allows a new attempt only after a terminal result and denies viewers and foreign records" do
    first = request_run(client: accepting_client, request_key: "web:first")
    ledger = ExecutionLedger.new(workspace: @workspace)
    ingest(ledger, first, 2, "run.started", adapter: "scripted", scenario: "failure", attempt: 1)
    ingest(ledger, first, 3, "run.failed", code: "fixture_failure", retryable: true)

    second = request_run(client: accepting_client, request_key: "web:second")
    assert_equal 2, second.attempt_number

    viewer = @workspace.memberships.create!(
      user: User.create!(email_address: "execution-viewer@example.com", password: "password12345", verified_at: Time.current),
      role: :viewer
    )
    assert_raises(Current::RoleAccessDenied) do
      ExecutionRecovery.request!(
        workspace: @workspace, membership: viewer, task: @task,
        request_key: "web:viewer", client: accepting_client
      )
    end

    foreign_workspace = workspaces(:beta_support)
    foreign_owner = memberships(:outsider_beta)
    CrewConfiguration.install_defaults!(workspace: foreign_workspace)
    foreign_case = create_support_case(workspace: foreign_workspace, contact: contacts(:bob), membership: foreign_owner)
    foreign_task = CrewWork.create!(
      workspace: foreign_workspace, membership: foreign_owner, scope: foreign_case,
      profile: foreign_workspace.agent_profiles.find_by!(role_key: "support_investigator"),
      title: "Foreign task", input_context: "Foreign context.", expected_output: "Foreign output."
    )
    assert_raises(ActiveRecord::RecordNotFound) do
      ExecutionRecovery.request!(
        workspace: @workspace, membership: @owner, task: foreign_task,
        request_key: "web:foreign", client: accepting_client
      )
    end
  end

  test "does not let task cancellation outrun an active execution" do
    request_run(client: accepting_client, request_key: "web:active")
    error = assert_raises(CrewWork::InvalidCommand) do
      CrewWork.apply!(
        workspace: @workspace, membership: @owner, task: @task.reload, command: :cancel,
        expected_sequence: @task.current_event.sequence_number, attributes: { body: "Stop work." }
      )
    end
    assert_match(/active run/, error.message)
    assert @task.reload.in_progress?
  end

  private
    def request_run(client:, request_key:)
      ExecutionRecovery.request!(
        workspace: @workspace, membership: @owner, task: @task,
        request_key:, client:
      )
    end

    def accepting_client
      client = Object.new
      client.define_singleton_method(:calls) { @calls.to_i }
      client.define_singleton_method(:admit!) do |task:, run_id:, attempt:, **|
        @calls = @calls.to_i + 1
        event = {
          "protocol_version" => "v1", "event_id" => SecureRandom.uuid, "run_id" => run_id,
          "sequence" => 1, "event_type" => "run.admitted", "occurred_at" => Time.current.iso8601(6),
          "data" => { "workspace_key" => task.workspace.runner_key, "task_key" => task.task_key, "attempt" => attempt }
        }
        Struct.new(:event).new(event)
      end
      client
    end

    def rejecting_client
      Object.new.tap do |client|
        client.define_singleton_method(:admit!) { |**| raise RunnerClient::AmbiguousResult, "unknown" }
      end
    end

    def ingest(ledger, run, sequence, type, **data)
      ledger.ingest!(event: {
        "protocol_version" => "v1", "event_id" => SecureRandom.uuid, "run_id" => run.run_key,
        "sequence" => sequence, "event_type" => type,
        "occurred_at" => (Time.current + sequence.fdiv(1_000_000)).iso8601(6),
        "data" => data.deep_stringify_keys
      })
    end
end
