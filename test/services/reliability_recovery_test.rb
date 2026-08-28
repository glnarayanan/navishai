require "test_helper"

class ReliabilityRecoveryTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
    approve_scripted_runtime(workspace: @workspace, membership: @owner)
    CrewConfiguration.install_defaults!(workspace: @workspace)
    @support_case = create_support_case
    @task = CrewWork.create!(
      workspace: @workspace, membership: @owner, scope: @support_case,
      profile: @workspace.agent_profiles.find_by!(role_key: "support_investigator"),
      title: "Recover a run", input_context: "Use retained facts.", expected_output: "Return a finding."
    )
    CrewWork.apply!(
      workspace: @workspace, membership: @owner, task: @task, command: :start,
      expected_sequence: @task.current_event.sequence_number
    )
  end

  test "reconciles one ambiguous admission without creating another run" do
    assert_raises(RunnerClient::AmbiguousResult) do
      ExecutionRecovery.request!(
        workspace: @workspace, membership: @owner, task: @task,
        request_key: "reliability:ambiguous", client: ambiguous_client
      )
    end
    run = @task.execution_runs.sole

    assert_no_difference "ExecutionRun.count" do
      assert_difference -> { @workspace.audit_events.where(action: "execution.run_reconciled").count }, 1 do
        ReliabilityRecovery.reconcile_run!(
          workspace: @workspace, membership: @owner, run:, client: accepting_client
        )
      end
    end
    assert run.reload.admitted?
  end

  test "retries a definite failure once with a deterministic request key" do
    failed = ExecutionRecovery.request!(
      workspace: @workspace, membership: @owner, task: @task,
      request_key: "reliability:first", client: accepting_client
    )
    ledger = ExecutionLedger.new(workspace: @workspace)
    ingest(ledger, failed, 2, "run.started", adapter: "scripted", scenario: "failure", attempt: 1)
    ingest(ledger, failed, 3, "run.failed", code: "fixture_failure", retryable: true)

    assert_difference "ExecutionRun.count", 1 do
      @retry = ReliabilityRecovery.retry_run!(
        workspace: @workspace, membership: @owner, run: failed, client: accepting_client
      )
    end
    assert_equal "operations:retry:#{failed.run_key}", @retry.request_key
    assert @retry.admitted?

    assert_no_difference "ExecutionRun.count" do
      replay = ReliabilityRecovery.retry_run!(
        workspace: @workspace, membership: @owner, run: failed, client: ambiguous_client
      )
      assert_equal @retry, replay
    end
  end

  test "refuses a nonretryable or foreign run and refreshes manager authority" do
    run = ExecutionRecovery.request!(
      workspace: @workspace, membership: @owner, task: @task,
      request_key: "reliability:nonretryable", client: accepting_client
    )
    ledger = ExecutionLedger.new(workspace: @workspace)
    ingest(ledger, run, 2, "run.started", adapter: "scripted", scenario: "failure", attempt: 1)
    ingest(ledger, run, 3, "run.failed", code: "terminal_failure", retryable: false)

    assert_raises(ReliabilityRecovery::InvalidAction) do
      ReliabilityRecovery.retry_run!(workspace: @workspace, membership: @owner, run:, client: accepting_client)
    end
    cockpit = ReliabilityCockpit.build(
      workspace: @workspace, membership: @owner, queue_snapshot: { status: "not_configured" }
    )
    terminal_item = cockpit.groups.index_by(&:key).fetch("execution").items.find do |item|
      item.key == "run-#{run.id}"
    end
    assert_equal "blocked", terminal_item.status
    assert_nil terminal_item.action

    member = @workspace.memberships.create!(
      user: User.create!(email_address: "recovery-member@example.com", password: "password12345", verified_at: Time.current),
      role: :member
    )
    assert_raises(Current::RoleAccessDenied) do
      ReliabilityRecovery.retry_run!(workspace: @workspace, membership: member, run:, client: accepting_client)
    end
    foreign_manager = workspaces(:beta_support).memberships.create!(
      user: User.create!(email_address: "foreign-recovery-manager@example.com", password: "password12345", verified_at: Time.current),
      role: :manager
    )
    assert_raises(ActiveRecord::RecordNotFound) do
      ReliabilityRecovery.retry_run!(
        workspace: workspaces(:beta_support), membership: foreign_manager,
        run:, client: accepting_client
      )
    end
  end

  private
    def accepting_client
      Object.new.tap do |client|
        client.define_singleton_method(:admit!) do |task:, run_id:, attempt:, **|
          event = {
            "protocol_version" => "v1", "event_id" => SecureRandom.uuid, "run_id" => run_id,
            "sequence" => 1, "event_type" => "run.admitted", "occurred_at" => Time.current.iso8601(6),
            "data" => { "workspace_key" => task.workspace.runner_key, "task_key" => task.task_key, "attempt" => attempt }
          }
          Struct.new(:event).new(event)
        end
      end
    end

    def ambiguous_client
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
