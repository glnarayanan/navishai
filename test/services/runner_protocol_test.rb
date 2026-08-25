require "test_helper"

class RunnerProtocolTest < ActiveSupport::TestCase
  FIXTURE_PATH = Rails.root.join("test/fixtures/files/runner_protocol/v1")

  test "parses the shared admission fixture" do
    request = RunnerProtocol::AdmissionRequest.parse(File.binread(FIXTURE_PATH.join("admission_request.json")))

    assert_equal RunnerProtocol::VERSION, request.attributes.fetch("protocol_version")
    assert_equal "support_investigator", request.attributes.dig("agent", "role_key")
    assert_equal 20, request.attributes.dig("agent", "max_tool_calls")
  end

  test "matches the shared signature vector" do
    vector = JSON.parse(File.binread(FIXTURE_PATH.join("signature_vector.json")))

    assert_equal vector.fetch("signature"), RunnerProtocol.signature(
      secret: vector.fetch("secret"), timestamp: vector.fetch("timestamp"),
      method: vector.fetch("method"), path: vector.fetch("path"), body: vector.fetch("body")
    )
  end

  test "builds admission from the frozen task policy" do
    profile = Data.define(:role_key).new("support_investigator")
    version = Data.define(
      :version_number, :instructions, :allowed_tools, :runtime_profile_key,
      :fallback_profile_keys, :timeout_seconds, :max_steps, :max_tool_calls, :review_policy
    ).new(3, "Investigate current evidence.", %w[knowledge_search case_read], "workspace_default", [ "fast" ], 300, 10, 20, "required")
    workspace = Data.define(:runner_key).new("c9bb966b-1fe9-4304-bd51-404e4fd9a09c")
    task = Data.define(
      :workspace, :task_key, :title, :input_context, :expected_output,
      :assigned_agent_profile, :assigned_agent_profile_version
    ).new(
      workspace, "fae7db72-e33b-46b9-8f9e-9a0dfdd56661", "Investigate sign-in failure",
      "Use the current case conversation.", "State the cause and cite evidence.", profile, version
    )

    request = RunnerProtocol::AdmissionRequest.for_task(
      task:, run: Data.define(
        :selected_runtime_detection_key, :selected_adapter_key, :selected_runtime_profile_key,
        :runtime_selection_reason, :runtime_selection_detail, :disclosed_data_classes,
        :max_input_units, :max_output_units
      ).new(
        "b" * 64, "scripted", "workspace_default", "primary",
        "Primary Workspace default profile selected.", %w[approved_knowledge case_content], 100_000, 25_000
      ), run_id: "3d07f334-88ef-4fe4-a640-421e3ba79921",
      idempotency_key: "admit:3d07f334-88ef-4fe4-a640-421e3ba79921", attempt: 1
    )

    assert_equal task.task_key, request.attributes.dig("task", "task_key")
    assert_equal %w[case_read knowledge_search], request.attributes.dig("agent", "allowed_tools")
    assert_equal 3, request.attributes.dig("agent", "policy_version")
  end

  test "rejects unknown fields and mismatched admission responses" do
    body = JSON.parse(File.binread(FIXTURE_PATH.join("admission_request.json")))
    body["provider"] = "specific"
    assert_raises(RunnerProtocol::MalformedMessage) { RunnerProtocol::AdmissionRequest.parse(JSON.generate(body)) }

    response = {
      protocol_version: "v1", run_id: "3d07f334-88ef-4fe4-a640-421e3ba79921", status: "accepted",
      event: {
        protocol_version: "v1", event_id: "55a4662d-aef5-4d14-8552-a57b57f2f01e",
        run_id: "3d07f334-88ef-4fe4-a640-421e3ba79921", sequence: 1,
        event_type: "run.admitted", occurred_at: "2026-08-24T12:00:00Z",
        data: { workspace_key: "c9bb966b-1fe9-4304-bd51-404e4fd9a09c", task_key: "fae7db72-e33b-46b9-8f9e-9a0dfdd56661", attempt: 1 }
      }
    }
    assert_raises(RunnerProtocol::MalformedMessage) do
      RunnerProtocol::AdmissionResponse.parse(JSON.generate(response), expected_run_id: SecureRandom.uuid)
    end
  end

  test "bounds assembled run context at 128 KiB" do
    body = JSON.parse(File.binread(FIXTURE_PATH.join("admission_request.json")))
    body.fetch("task")["input_context"] = "x" * 128.kilobytes
    assert RunnerProtocol::AdmissionRequest.parse(JSON.generate(body))

    body.fetch("task")["input_context"] << "x"
    assert_raises(RunnerProtocol::MalformedMessage) do
      RunnerProtocol::AdmissionRequest.parse(JSON.generate(body))
    end
  end

  test "parses strict provider-neutral public web results" do
    workspace_key = "c9bb966b-1fe9-4304-bd51-404e4fd9a09c"
    payload = {
      protocol_version: "v1", workspace_key:, request_key: "search:one", query: "status incident",
      provider_key: "searxng", policy_decision: "allowed", cost_units: 1,
      retrieved_at: "2026-08-24T12:00:00Z",
      results: [ {
        rank: 1, title: "Incident report", url: "https://status.example.com/incidents/1",
        excerpt: "The service recovered.", published_at: "2026-08-24T11:00:00Z"
      } ]
    }

    response = RunnerProtocol::WebSearchResponse.parse(
      JSON.generate(payload), workspace_key:, request_key: "search:one", query: "status incident"
    )
    assert_equal "searxng", response.attributes.fetch("provider_key")
    assert_equal "Incident report", response.attributes.fetch("results").sole.fetch("title")

    payload[:results].first[:url] = "https://status.example.com/incidents/1#untrusted"
    assert_raises(RunnerProtocol::MalformedMessage) do
      RunnerProtocol::WebSearchResponse.parse(
        JSON.generate(payload), workspace_key:, request_key: "search:one", query: "status incident"
      )
    end
    payload[:results].first[:url] = "https://status.example.com/incidents/1"
    payload[:provider_name] = "specific"
    assert_raises(RunnerProtocol::MalformedMessage) do
      RunnerProtocol::WebSearchResponse.parse(
        JSON.generate(payload), workspace_key:, request_key: "search:one", query: "status incident"
      )
    end
  end
end
