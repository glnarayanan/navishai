require "test_helper"

class ProviderConnectionGatewayTest < ActiveSupport::TestCase
  test "signs catalog configure remove and workspace purge requests and validates exact responses" do
    secret = "s" * 32
    now = Time.iso8601("2026-08-31T12:00:00Z")
    workspace_key = "c9bb966b-1fe9-4304-bd51-404e4fd9a09c"
    request_id = "3d07f334-88ef-4fe4-a640-421e3ba79921"
    provider = provider_payload
    gateway = ProviderConnectionGateway.new(secret:, clock: -> { now })
    captured = []
    gateway.define_singleton_method(:perform) do |request, read_timeout:|
      captured << [ request, read_timeout ]
      response_provider = if request.path == ProviderConnectionProtocol::REMOVE_PATH
        provider.merge("configured" => false, "secret_configured" => false, "auth_mode" => "", "model" => "", "health_status" => "not_configured")
      else
        provider
      end
      body = if request.path == ProviderConnectionProtocol::CATALOG_PATH
        JSON.generate(protocol_version: "v1", workspace_key:, providers: [ response_provider ])
      elsif request.path == ProviderConnectionProtocol::PURGE_WORKSPACE_PATH
        JSON.generate(protocol_version: "v1", workspace_key:, purged: true)
      else
        JSON.generate(protocol_version: "v1", workspace_key:, provider: response_provider)
      end
      RunnerClient::Response.new(code: 200, body:)
    end

    assert_equal "codex", gateway.catalog(workspace_key:).sole.fetch("adapter_key")
    gateway.configure(
      workspace_key:, request_id:, adapter_key: "codex", auth_mode: "api_key", model: "gpt-5.6",
      api_key: "one-time-key"
    )
    gateway.remove(workspace_key:, request_id:, adapter_key: "codex")
    assert gateway.purge_workspace(workspace_key:)

    assert_equal [
      ProviderConnectionProtocol::CATALOG_PATH,
      ProviderConnectionProtocol::CONFIGURE_PATH,
      ProviderConnectionProtocol::REMOVE_PATH,
      ProviderConnectionProtocol::PURGE_WORKSPACE_PATH
    ], captured.map { |request, _timeout| request.path }
    assert_equal 55, captured.second.last
    configure_request = captured.second.first
    assert_equal "one-time-key", JSON.parse(configure_request.body).fetch("api_key")
    purge_request = JSON.parse(captured.fourth.first.body)
    assert_equal "v1", purge_request.fetch("protocol_version")
    assert_match RunnerProtocol::UUID_PATTERN, purge_request.fetch("request_id")
    captured.each do |request, _timeout|
      assert_equal RunnerProtocol.signature(
        secret:, timestamp: now.to_i.to_s, method: "POST", path: request.path, body: request.body
      ), request["X-NavishAI-Signature"]
    end
  end

  test "rejects extra fields and mismatched workspaces" do
    workspace_key = "c9bb966b-1fe9-4304-bd51-404e4fd9a09c"
    provider = provider_payload.merge("api_key" => "must-not-be-accepted")

    assert_raises(ProviderConnectionProtocol::MalformedMessage) do
      ProviderConnectionProtocol.parse_catalog(
        JSON.generate(protocol_version: "v1", workspace_key:, providers: [ provider ]), workspace_key:
      )
    end
    assert_raises(ProviderConnectionProtocol::MalformedMessage) do
      ProviderConnectionProtocol.parse_provider(
        JSON.generate(protocol_version: "v1", workspace_key: SecureRandom.uuid, provider: provider_payload),
        workspace_key:
      )
    end
  end

  private
    def provider_payload
      {
        "adapter_key" => "codex", "name" => "Codex", "description" => "Use Codex for workspace tasks.",
        "auth_modes" => %w[api_key subscription], "model_required" => true, "configured" => true,
        "secret_configured" => true, "auth_mode" => "api_key", "model" => "gpt-5.6",
        "health_status" => "available", "available" => true, "executable_version" => "codex 1.2.3"
      }
    end
end
