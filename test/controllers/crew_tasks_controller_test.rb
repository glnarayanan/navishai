require "test_helper"

class CrewTasksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
    approve_scripted_runtime(workspace: @workspace, membership: @owner)
    CrewConfiguration.install_defaults!(workspace: @workspace)
    @support_case = create_support_case
    @profile = @workspace.agent_profiles.find_by!(role_key: "support_coordinator")
    sign_in_as @owner.user
  end

  test "case crew workspace creates and advances an attributable task" do
    get workspace_support_case_crew_tasks_path(@workspace, @support_case)
    assert_response :success
    assert_select "h1", "Crew work"
    assert_select ".crew-progress dd", text: "0", count: 3

    assert_difference [ "CrewTask.count", "CrewTaskEvent.count" ], 1 do
      post workspace_support_case_crew_tasks_path(@workspace, @support_case), params: {
        title: "Investigate access failure",
        input_context: "Use the current case conversation.",
        expected_output: "Find the cause, cite the case record, and state uncertainty.",
        agent_profile_id: @profile.id
      }
    end
    task = @support_case.crew_tasks.find_by!(title: "Investigate access failure")
    assert_redirected_to workspace_support_case_crew_task_path(@workspace, @support_case, task)

    assert_difference "CrewTaskEvent.count", 1 do
      post command_workspace_support_case_crew_task_path(@workspace, @support_case, task), params: {
        command_name: "start", expected_sequence: task.current_event.sequence_number
      }
    end
    assert_redirected_to workspace_support_case_crew_task_path(@workspace, @support_case, task)
    assert task.reload.in_progress?

    get workspace_support_case_crew_task_path(@workspace, @support_case, task)
    assert_response :success
    assert_select "h1", "Investigate access failure"
    assert_select ".crew-event-list li", count: 2
    assert_select ".crew-task-actions", text: /Coordinator \/ Triage/
  end

  test "invalid and stale commands rerender without changing durable work" do
    post workspace_support_case_crew_tasks_path(@workspace, @support_case), params: {
      title: " ", input_context: " ", expected_output: " ", agent_profile_id: @profile.id
    }
    assert_response :unprocessable_content
    assert_select ".inline-error", text: /Title can't be blank/

    task = CrewWork.create!(workspace: @workspace, membership: @owner, scope: @support_case,
      profile: @profile, title: "Current task", input_context: "Use current case facts.",
      expected_output: "Produce an evidence-backed result.")
    old_sequence = task.current_event.sequence_number
    CrewWork.apply!(workspace: @workspace, membership: @owner, task:, command: :start,
      expected_sequence: old_sequence)

    assert_no_difference "CrewTaskEvent.count" do
      post command_workspace_support_case_crew_task_path(@workspace, @support_case, task), params: {
        command_name: "comment", expected_sequence: old_sequence, body: "Stale note"
      }
    end
    assert_response :unprocessable_content
    assert_select ".inline-error", text: /changed after the page loaded/
  end

  test "viewer reads but cannot write and foreign paths fail closed" do
    task = CrewWork.create!(workspace: @workspace, membership: @owner, scope: @support_case,
      profile: @profile, title: "Visible task", input_context: "Use current case facts.",
      expected_output: "Keep work visible.")
    viewer_user = User.create!(email_address: "crew-ui-viewer@example.com", password: "password12345", verified_at: Time.current)
    @workspace.memberships.create!(user: viewer_user, role: :viewer)
    sign_in_as viewer_user

    get workspace_support_case_crew_task_path(@workspace, @support_case, task)
    assert_response :success
    assert_select ".read-only-notice", text: /Read-only access/
    assert_select ".crew-command-form", count: 0

    assert_no_difference [ "CrewTask.count", "CrewTaskEvent.count" ] do
      post workspace_support_case_crew_tasks_path(@workspace, @support_case), params: {
        title: "Forged", input_context: "Denied", expected_output: "Denied", agent_profile_id: @profile.id
      }
    end
    assert_response :forbidden

    foreign_case = create_support_case(
      workspace: workspaces(:beta_support), contact: contacts(:bob), membership: memberships(:outsider_beta)
    )
    get workspace_support_case_crew_tasks_path(@workspace, foreign_case)
    assert_response :not_found
  end

  test "run panel is tenant scoped and only writers can request or reconcile attempts" do
    task = CrewWork.create!(workspace: @workspace, membership: @owner, scope: @support_case,
      profile: @profile, title: "Run task", input_context: "Use current case facts.",
      expected_output: "Keep progress visible.")
    CrewWork.apply!(workspace: @workspace, membership: @owner, task:, command: :start,
      expected_sequence: task.current_event.sequence_number)
    client = accepting_runner_client

    with_runner_client(client) do
      post workspace_support_case_crew_task_execution_runs_path(@workspace, @support_case, task),
        params: { request_key: "web:controller" }
    end
    run = task.execution_runs.find_by!(request_key: "web:controller")
    assert_redirected_to workspace_support_case_crew_task_path(@workspace, @support_case, task)
    assert run.admitted?
    follow_redirect!

    get workspace_support_case_crew_task_execution_runs_path(@workspace, @support_case, task)
    assert_response :success
    assert_select "turbo-frame#task-execution-runs[data-run-poll-active-value='true']"
    assert_select "[data-run-poll-error-template] .run-poll-error", text: /Run panel refresh delayed/
    assert_select ".run-current", text: /Accepted by runner/
    etag = response.headers.fetch("ETag")
    cache_control = response.headers.fetch("Cache-Control")
    assert_includes cache_control, "private"

    rendered = []
    subscriber = ->(event) { rendered << event.payload[:identifier] }
    ActiveSupport::Notifications.subscribed(subscriber, "render_partial.action_view") do
      get workspace_support_case_crew_task_execution_runs_path(@workspace, @support_case, task),
        headers: { "If-None-Match" => etag }
    end
    assert_response :not_modified
    assert_empty response.body
    assert_empty rendered
    assert_equal cache_control, response.headers["Cache-Control"]

    ledger = ExecutionLedger.new(workspace: @workspace)
    base = run.current_event.occurred_at
    ingest_run_event(ledger, run, 2, "run.started", base + 1.second,
      adapter: "scripted", scenario: "failure", attempt: 1)
    ingest_run_event(ledger, run, 3, "run.failed", base + 2.seconds,
      code: "fixture_failure", retryable: true)
    get workspace_support_case_crew_task_execution_runs_path(@workspace, @support_case, task),
      headers: { "If-None-Match" => etag }
    assert_response :success
    assert_select "turbo-frame#task-execution-runs[data-run-poll-active-value='false']"
    assert_select ".execution-alert-error", text: /Run did not complete/
    assert_select "form[action='#{workspace_support_case_crew_task_execution_runs_path(@workspace, @support_case, task)}']",
      text: /Run specialist again/
    etag = response.headers.fetch("ETag")

    with_runner_client(client) do
      post workspace_support_case_crew_task_execution_runs_path(@workspace, @support_case, task),
        params: { request_key: "web:controller-second" }
    end
    get workspace_support_case_crew_task_execution_runs_path(@workspace, @support_case, task),
      headers: { "If-None-Match" => etag }
    assert_response :success
    assert_select ".run-history summary", text: "Earlier attempts (1)"
    assert_select "turbo-frame#task-execution-runs[data-run-poll-active-value='true']"
    etag = response.headers.fetch("ETag")

    viewer = @workspace.memberships.create!(
      user: User.create!(email_address: "run-panel-viewer@example.com", password: "password12345", verified_at: Time.current),
      role: :viewer
    )
    sign_in_as viewer.user
    get workspace_support_case_crew_task_execution_runs_path(@workspace, @support_case, task),
      headers: { "If-None-Match" => etag }
    assert_response :success
    assert_select ".run-action", count: 0
    assert_no_difference "ExecutionRun.count" do
      post workspace_support_case_crew_task_execution_runs_path(@workspace, @support_case, task),
        params: { request_key: "web:forged" }
    end
    assert_response :forbidden

    foreign_case = create_support_case(
      workspace: workspaces(:beta_support), contact: contacts(:bob), membership: memberships(:outsider_beta)
    )
    get workspace_support_case_crew_task_execution_runs_path(@workspace, foreign_case, task),
      headers: { "If-None-Match" => etag }
    assert_response :not_found
  end

  test "run panel validator includes task state before the first attempt" do
    task = CrewWork.create!(workspace: @workspace, membership: @owner, scope: @support_case,
      profile: @profile, title: "Unstarted task", input_context: "Use current case facts.",
      expected_output: "Keep progress visible.")
    path = workspace_support_case_crew_task_execution_runs_path(@workspace, @support_case, task)
    get path
    assert_response :success
    assert_select ".run-action", count: 0
    etag = response.headers.fetch("ETag")

    CrewWork.apply!(workspace: @workspace, membership: @owner, task:, command: :start,
      expected_sequence: task.current_event.sequence_number)
    get path, headers: { "If-None-Match" => etag }
    assert_response :success
    assert_select ".run-action", text: "Run specialist"

    ledger = ExecutionLedger.new(workspace: @workspace)
    run = ledger.prepare!(task:, request_key: "web:conditional-admission")
    client = Object.new
    client.define_singleton_method(:admit!) { |**| raise RunnerClient::AmbiguousResult, "connection_lost" }
    2.times do
      get path
      etag = response.headers.fetch("ETag")
      assert_raises(RunnerClient::AmbiguousResult) { ledger.admit!(run:, client:) }
      get path, headers: { "If-None-Match" => etag }
      assert_response :success
      assert_not_equal etag, response.headers["ETag"]
      assert_select ".run-current", text: /Runner connection degraded/
    end
  end

  test "account crew workspace uses Customer Success specialists and account-scoped run routes" do
    account = accounts(:acme)
    profile = @workspace.agent_profiles.find_by!(role_key: "risk_investigator")

    get workspace_account_crew_tasks_path(@workspace, account)
    assert_response :success
    assert_select "h2", text: "Account plan"
    assert_select "option", text: profile.name
    assert_select "option", text: @profile.name, count: 0

    post workspace_account_crew_tasks_path(@workspace, account), params: {
      title: "Review renewal risk", input_context: "Use retained account evidence.",
      expected_output: "Return a cited risk analysis with uncertainty.", agent_profile_id: profile.id
    }
    task = account.crew_tasks.find_by!(title: "Review renewal risk")
    assert_redirected_to workspace_account_crew_task_path(@workspace, account, task)

    post command_workspace_account_crew_task_path(@workspace, account, task), params: {
      command_name: "start", expected_sequence: task.current_event.sequence_number
    }
    assert task.reload.in_progress?
    get workspace_account_crew_task_path(@workspace, account, task)
    assert_response :success
    assert_select "turbo-frame#task-execution-runs[data-run-poll-url-value=?]",
      workspace_account_crew_task_execution_runs_path(@workspace, account, task)
  end

  private
    def with_runner_client(client)
      original = RunnerClient.method(:new)
      RunnerClient.define_singleton_method(:new) { client }
      yield
    ensure
      RunnerClient.define_singleton_method(:new, original)
    end

    def accepting_runner_client
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

    def ingest_run_event(ledger, run, sequence, type, occurred_at, **data)
      ledger.ingest!(event: {
        "protocol_version" => "v1", "event_id" => SecureRandom.uuid, "run_id" => run.run_key,
        "sequence" => sequence, "event_type" => type, "occurred_at" => occurred_at.iso8601(6),
        "data" => data.deep_stringify_keys
      })
    end
end
