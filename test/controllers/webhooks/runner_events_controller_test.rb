require "test_helper"

class Webhooks::RunnerEventsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:acme_support)
    @secret = "runner-event-secret-that-is-at-least-32-bytes"
    @original_secret = ENV["NAVISHAI_RUNNER_SHARED_SECRET"]
    ENV["NAVISHAI_RUNNER_SHARED_SECRET"] = @secret
    CrewConfiguration.install_defaults!(workspace: @workspace)
    support_case = create_support_case
    profile = @workspace.agent_profiles.find_by!(role_key: "support_investigator")
    task = CrewWork.create!(
      workspace: @workspace, membership: memberships(:owner_support), scope: support_case, profile:,
      title: "Investigate webhook intake", input_context: "Use the current case.",
      expected_output: "Return a grounded result."
    )
    @run = ExecutionLedger.new(workspace: @workspace).prepare!(task:, request_key: "webhook:test")
  end

  teardown do
    ENV["NAVISHAI_RUNNER_SHARED_SECRET"] = @original_secret
  end

  test "accepts authenticated events and exact replay without a browser session" do
    body = event_body(1, "run.admitted",
      workspace_key: @workspace.runner_key, task_key: @run.crew_task.task_key, attempt: 1)

    assert_difference "ExecutionEvent.count", 1 do
      post webhooks_runner_events_path, params: body, headers: signed_headers(body)
      assert_response :accepted
      assert_equal 1, response.parsed_body.fetch("sequence")
    end
    assert_no_difference "ExecutionEvent.count" do
      post webhooks_runner_events_path, params: body, headers: signed_headers(body)
      assert_response :accepted
    end
  end

  test "rejects bad authentication, changed replay, gaps, and foreign workspace audience" do
    body = event_body(1, "run.admitted",
      workspace_key: @workspace.runner_key, task_key: @run.crew_task.task_key, attempt: 1)

    assert_no_difference "ExecutionEvent.count" do
      post webhooks_runner_events_path, params: body,
        headers: signed_headers(body).merge("X-NavishAI-Signature" => "bad")
      assert_response :unauthorized
    end

    post webhooks_runner_events_path, params: body, headers: signed_headers(body)
    assert_response :accepted

    changed = JSON.parse(body)
    changed.fetch("data")["attempt"] = 2
    changed_body = JSON.generate(changed)
    post webhooks_runner_events_path, params: changed_body, headers: signed_headers(changed_body)
    assert_response :conflict

    gap = event_body(3, "run.started", adapter: "scripted", scenario: "gap", attempt: 1)
    post webhooks_runner_events_path, params: gap, headers: signed_headers(gap)
    assert_response :conflict

    post webhooks_runner_events_path, params: gap,
      headers: signed_headers(gap).merge("X-NavishAI-Workspace-Key" => workspaces(:beta_support).runner_key)
    assert_response :not_found
  end

  test "bounds the body and requires JSON after authentication" do
    oversized = "x" * (RunnerProtocol::MAX_BODY_BYTES + 1)
    post webhooks_runner_events_path, params: oversized, headers: signed_headers(oversized)
    assert_response :content_too_large

    body = event_body(1, "run.admitted",
      workspace_key: @workspace.runner_key, task_key: @run.crew_task.task_key, attempt: 1)
    post webhooks_runner_events_path, params: body,
      headers: signed_headers(body).merge("CONTENT_TYPE" => "text/plain")
    assert_response :unsupported_media_type
    assert_empty @run.events
  end

  private
    def event_body(sequence, type, **data)
      JSON.generate(
        protocol_version: "v1", event_id: SecureRandom.uuid, run_id: @run.run_key,
        sequence:, event_type: type, occurred_at: Time.current.iso8601(6), data:
      )
    end

    def signed_headers(body, timestamp = Time.current.to_i)
      {
        "CONTENT_TYPE" => "application/json",
        "X-NavishAI-Timestamp" => timestamp.to_s,
        "X-NavishAI-Signature" => RunnerProtocol.signature(
          secret: @secret, timestamp: timestamp.to_s, method: "POST",
          path: webhooks_runner_events_path, body:
        ),
        "X-NavishAI-Workspace-Key" => @workspace.runner_key
      }
    end
end
