require "test_helper"

class RunnerClientTest < ActiveSupport::TestCase
  test "rejects short secrets and cleartext non-loopback addresses" do
    assert_raises(RunnerClient::ConfigurationError) { RunnerClient.new(secret: "short") }
    assert_raises(RunnerClient::ConfigurationError) do
      RunnerClient.new(address: "http://runner.internal:8081", secret: "s" * 32)
    end
  end

  test "parses an accepted response and maps protocol failures" do
    client = RunnerClient.new(secret: "s" * 32)
    response_body = JSON.generate(
      protocol_version: "v1", run_id: "3d07f334-88ef-4fe4-a640-421e3ba79921", status: "accepted",
      event: {
        protocol_version: "v1", event_id: "55a4662d-aef5-4d14-8552-a57b57f2f01e",
        run_id: "3d07f334-88ef-4fe4-a640-421e3ba79921", sequence: 1,
        event_type: "run.admitted", occurred_at: "2026-08-24T12:00:00Z",
        data: { workspace_key: "c9bb966b-1fe9-4304-bd51-404e4fd9a09c", task_key: "fae7db72-e33b-46b9-8f9e-9a0dfdd56661", attempt: 1 }
      }
    )

    parsed = client.send(:parse_admission, response_body, "3d07f334-88ef-4fe4-a640-421e3ba79921")
    assert_equal "run.admitted", parsed.event.fetch("event_type")

    error = RunnerClient::Response.new(
      code: 409,
      body: JSON.generate(protocol_version: "v1", error: { code: "idempotency_conflict", message: "Key conflict." })
    )
    assert_raises(RunnerClient::Conflict) { client.send(:raise_for_response, error) }
  end

  test "rejects malformed and oversized accepted responses" do
    client = RunnerClient.new(secret: "s" * 32)

    assert_raises(RunnerClient::MalformedResponse) do
      client.send(:parse_admission, "{}", "3d07f334-88ef-4fe4-a640-421e3ba79921")
    end
    assert_raises(RunnerClient::MalformedResponse) do
      client.send(:parse_admission, " " * (RunnerProtocol::MAX_BODY_BYTES + 1), "3d07f334-88ef-4fe4-a640-421e3ba79921")
    end
  end

  test "parses strict runtime detection reports" do
    report = {
      detection_key: "a" * 64, adapter_key: "fixture", protocol_version: "v1",
      executable_path: "/opt/fixture", executable_version: "fixture 1.0.0",
      account_metadata: { authentication: "managed_on_runner" }, capabilities: [ "structured_output" ],
      minimum_version: "1.0.0", maximum_version: "1.x", compatibility_status: "compatible",
      incompatibility_reason: "", health_status: "available", checked_at: "2026-08-24T12:00:00Z"
    }
    parsed = RunnerProtocol::RuntimeDetectionResponse.parse(JSON.generate(protocol_version: "v1", installations: [ report ]))
    assert_equal "/opt/fixture", parsed.installations.sole.fetch("executable_path")

    report[:account_metadata] = { access_token: "secret" }
    assert_raises(RunnerProtocol::MalformedMessage) do
      RunnerProtocol::RuntimeDetectionResponse.parse(JSON.generate(protocol_version: "v1", installations: [ report ]))
    end
  end

  test "signs and validates a public web search request" do
    secret = "s" * 32
    now = Time.iso8601("2026-08-24T12:00:00Z")
    workspace_key = "c9bb966b-1fe9-4304-bd51-404e4fd9a09c"
    response = RunnerClient::Response.new(
      code: 200,
      body: JSON.generate(
        protocol_version: "v1", workspace_key:, request_key: "search:one", query: "status incident",
        provider_key: "searxng", policy_decision: "allowed", cost_units: 1,
        retrieved_at: now.iso8601, results: []
      )
    )
    client = RunnerClient.new(secret:, clock: -> { now })
    captured = nil
    client.define_singleton_method(:perform) do |request|
      captured = request
      response
    end

    result = client.web_search!(workspace_key:, request_key: "search:one", query: "status incident")

    assert_equal "searxng", result.fetch("provider_key")
    assert_equal RunnerProtocol::WEB_SEARCH_PATH, captured.path
    assert_equal RunnerProtocol.signature(
      secret:, timestamp: now.to_i.to_s, method: "POST", path: captured.path, body: captured.body
    ), captured["X-NavishAI-Signature"]
  end
end
