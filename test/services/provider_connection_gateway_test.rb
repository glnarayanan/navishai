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

  test "signs model discovery requests with an exact body and validates the bounded response" do
    secret = "s" * 32
    now = Time.iso8601("2026-08-31T12:00:00Z")
    workspace_key = "c9bb966b-1fe9-4304-bd51-404e4fd9a09c"
    adapter_key = "codex"
    gateway = ProviderConnectionGateway.new(secret:, clock: -> { now })
    response_body = JSON.generate(model_discovery_payload(workspace_key:, adapter_key:))
    captured = []
    gateway.define_singleton_method(:perform) do |request, read_timeout:|
      captured << [ request, read_timeout ]
      RunnerClient::Response.new(code: 200, body: response_body)
    end

    result = gateway.models(workspace_key:, adapter_key:)
    request, read_timeout = captured.first
    assert_equal ProviderConnectionProtocol::MODELS_PATH, request.path
    assert_equal 20, read_timeout
    assert_equal(
      { "protocol_version" => "v1", "workspace_key" => workspace_key, "adapter_key" => adapter_key },
      JSON.parse(request.body)
    )
    assert_equal RunnerProtocol.signature(
      secret:, timestamp: now.to_i.to_s, method: "POST", path: request.path, body: request.body
    ), request["X-NavishAI-Signature"]
    assert_equal "available", result.fetch("status")
    assert_equal workspace_key, result.fetch("workspace_key")
    assert_equal adapter_key, result.fetch("adapter_key")
    assert result.fetch("models").all? { |model| model.keys.sort == %w[default id label] }
    refute result.key?("api_key")
  end

  test "rejects malformed model discovery responses" do
    workspace_key = "c9bb966b-1fe9-4304-bd51-404e4fd9a09c"
    base = model_discovery_payload(workspace_key:)
    too_many_models = Array.new(101) do |index|
      { "id" => "model-#{index}", "label" => "Model #{index}", "default" => false }
    end
    invalid = {
      "extra response field" => base.merge("api_key" => "secret-must-not-cross-boundary"),
      "mismatched workspace" => base.merge("workspace_key" => SecureRandom.uuid),
      "mismatched adapter" => base.merge("adapter_key" => "cursor"),
      "invalid status" => base.merge("status" => "ready"),
      "invalid checked time" => base.merge("checked_at" => "not-a-time"),
      "oversized checked time" => base.merge("checked_at" => "x" * 65),
      "too many models" => base.merge("models" => too_many_models),
      "oversized ID" => base.merge("models" => [ model_options.first.merge("id" => "i" * 201) ]),
      "oversized label" => base.merge("models" => [ model_options.first.merge("label" => "l" * 201) ]),
      "duplicate IDs" => base.merge("models" => model_options + [ model_options.first.dup.merge("label" => "Other label") ]),
      "control in ID" => base.merge("models" => [ model_options.first.merge("id" => "gpt\n5.6") ]),
      "leading whitespace in label" => base.merge("models" => [ model_options.first.merge("label" => " GPT-5.6") ]),
      "trailing whitespace in ID" => base.merge("models" => [ model_options.first.merge("id" => "gpt-5.6 ") ]),
      "blank ID" => base.merge("models" => [ model_options.first.merge("id" => "   ") ]),
      "multiple defaults" => base.merge("models" => model_options.map { |model| model.merge("default" => true) }),
      "model extra field" => base.merge("models" => [ model_options.first.merge("secret" => "do-not-return") ]),
      "invalid default marker" => base.merge("models" => [ model_options.first.merge("default" => "yes") ]),
      "available without models" => base.merge("models" => []),
      "unsupported with models" => base.merge("status" => "unsupported"),
      "failed with models" => base.merge("status" => "failed")
    }

    invalid.each do |name, payload|
      assert_raises(ProviderConnectionProtocol::MalformedMessage, name) do
        ProviderConnectionProtocol.parse_models(JSON.generate(payload), workspace_key:, adapter_key: "codex")
      end
    end
  end

  test "accepts unsupported and failed discovery with explicit empty model arrays" do
    workspace_key = "c9bb966b-1fe9-4304-bd51-404e4fd9a09c"

    %w[unsupported failed].each do |status|
      payload = model_discovery_payload(workspace_key:, status:, models: [])
      result = ProviderConnectionProtocol.parse_models(
        JSON.generate(payload), workspace_key:, adapter_key: "codex"
      )
      assert_equal status, result.fetch("status")
      assert_equal [], result.fetch("models")
    end
  end

  test "maps read-only catalog and model timeouts to unavailable while mutations remain ambiguous" do
    gateway = ProviderConnectionGateway.new(secret: "s" * 32)
    gateway.define_singleton_method(:perform) do |_request, read_timeout:|
      raise Net::ReadTimeout, "timed out after #{read_timeout} seconds"
    end
    workspace_key = "c9bb966b-1fe9-4304-bd51-404e4fd9a09c"

    assert_raises(RunnerClient::Unavailable) { gateway.catalog(workspace_key:) }
    assert_raises(RunnerClient::Unavailable) { gateway.models(workspace_key:, adapter_key: "codex") }
    assert_raises(RunnerClient::AmbiguousResult) do
      gateway.configure(
        workspace_key:, request_id: SecureRandom.uuid, adapter_key: "codex", auth_mode: "api_key",
        model: "gpt-5.6", api_key: "one-time-key"
      )
    end
    assert_raises(RunnerClient::AmbiguousResult) do
      gateway.remove(workspace_key:, request_id: SecureRandom.uuid, adapter_key: "codex")
    end
    assert_raises(RunnerClient::AmbiguousResult) { gateway.purge_workspace(workspace_key:) }
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
    def model_discovery_payload(workspace_key:, adapter_key: "codex", status: "available", models: nil)
      {
        "protocol_version" => "v1", "workspace_key" => workspace_key, "adapter_key" => adapter_key,
        "status" => status, "checked_at" => "2026-08-31T12:00:00Z", "models" => models || model_options
      }
    end

    def model_options
      [
        { "id" => "gpt-5.6", "label" => "GPT-5.6", "default" => true },
        { "id" => "gpt-5.5", "label" => "GPT-5.5", "default" => false }
      ]
    end

    def provider_payload
      {
        "adapter_key" => "codex", "name" => "Codex", "description" => "Use Codex for workspace tasks.",
        "auth_modes" => %w[api_key subscription], "model_required" => true, "configured" => true,
        "secret_configured" => true, "auth_mode" => "api_key", "model" => "gpt-5.6",
        "health_status" => "available", "available" => true, "executable_version" => "codex 1.2.3"
      }
    end
end
