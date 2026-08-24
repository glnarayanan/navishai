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
end
