require "test_helper"

class ProviderConnectionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:acme_support)
    @gateway = FakeProviderGateway.new(provider_catalog)
  end

  test "only Owners and Admins can open or change provider connections" do
    user = User.create!(email_address: "provider-member@example.com", password: "password12345", verified_at: Time.current)
    @workspace.memberships.create!(user:, role: :member)
    sign_in_as user

    with_gateway(-> { flunk "runner must not be called" }) do
      get new_workspace_provider_connection_path(@workspace)
      assert_response :forbidden

      post workspace_provider_connections_path(@workspace), params: {
        provider_connection: { adapter_key: "codex", auth_mode: "api_key", model: "gpt-5", api_key: "should-not-leave" }
      }
      assert_response :forbidden

      post models_workspace_provider_connections_path(@workspace), params: { adapter_key: "codex", execution_mode: "bounded" }
      assert_response :forbidden
    end
  end

  test "an Owner gets sanitized model discovery for a configured provider" do
    sign_in_as users(:owner)
    @gateway.models_result = {
      "status" => "available", "checked_at" => "2026-08-31T12:00:00Z",
      "models" => [ { "id" => "gpt-5.6", "label" => "GPT-5.6", "default" => true } ],
      "workspace_key" => @workspace.runner_key, "adapter_key" => "codex", "execution_mode" => "bounded",
      "api_key" => "must-not-leak"
    }

    with_gateway(@gateway) do
      post models_workspace_provider_connections_path(@workspace), params: { adapter_key: "codex", execution_mode: "bounded" }
    end

    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "no-cache", response.headers["Pragma"]
    assert_equal(
      {
        "status" => "available", "checked_at" => "2026-08-31T12:00:00Z",
        "models" => [ { "id" => "gpt-5.6", "label" => "GPT-5.6", "default" => true } ]
      }, JSON.parse(response.body)
    )
    assert_equal [ [ @workspace.runner_key, "codex", "bounded" ] ], @gateway.models_calls
    assert_not_includes response.body, "must-not-leak"
  end

  test "an Owner receives unsupported and failed discovery states without inventing models" do
    sign_in_as users(:owner)

    %w[unsupported failed].each do |status|
      @gateway.models_result = {
        "status" => status, "checked_at" => "2026-08-31T12:00:00Z", "models" => []
      }
      with_gateway(@gateway) do
        post models_workspace_provider_connections_path(@workspace), params: { adapter_key: "codex", execution_mode: "bounded" }
      end

      assert_response :success
      assert_equal({ "status" => status, "checked_at" => "2026-08-31T12:00:00Z", "models" => [] }, JSON.parse(response.body))
    end
  end

  test "model discovery rejects a stale execution boundary before calling the runner" do
    sign_in_as users(:owner)

    with_gateway(@gateway) do
      post models_workspace_provider_connections_path(@workspace), params: {
        adapter_key: "codex", execution_mode: "host_trusted"
      }
    end

    assert_response :conflict
    assert_equal({ "status" => "failed", "models" => [] }, JSON.parse(response.body))
    assert_empty @gateway.models_calls
  end

  test "unknown, unconfigured, and invalid adapters return not found without discovery" do
    sign_in_as users(:owner)

    with_gateway(@gateway) do
      post models_workspace_provider_connections_path(@workspace), params: { adapter_key: "missing" }
      assert_response :not_found
      post models_workspace_provider_connections_path(@workspace), params: { adapter_key: "claude" }
      assert_response :not_found
      post models_workspace_provider_connections_path(@workspace), params: { adapter_key: "A" * 65 }
      assert_response :not_found
    end

    assert_empty @gateway.models_calls
  end

  test "unavailable and malformed discovery responses are stable and sanitized" do
    sign_in_as users(:owner)

    @gateway.models_error = RunnerClient::Unavailable.new("secret transport detail")
    with_gateway(@gateway) do
      post models_workspace_provider_connections_path(@workspace), params: { adapter_key: "codex", execution_mode: "bounded" }
    end
    assert_response :service_unavailable
    assert_equal({ "status" => "unavailable", "models" => [] }, JSON.parse(response.body))
    assert_not_includes response.body, "secret transport detail"

    @gateway.models_error = RunnerClient::MalformedResponse.new("raw provider output")
    with_gateway(@gateway) do
      post models_workspace_provider_connections_path(@workspace), params: { adapter_key: "codex", execution_mode: "bounded" }
    end
    assert_response :bad_gateway
    assert_equal({ "status" => "failed", "models" => [] }, JSON.parse(response.body))
    assert_not_includes response.body, "raw provider output"

    @gateway.models_error = RunnerClient::AuthenticationError.new("provider token detail")
    with_gateway(@gateway) do
      post models_workspace_provider_connections_path(@workspace), params: { adapter_key: "codex", execution_mode: "bounded" }
    end
    assert_response :bad_gateway
    assert_equal({ "status" => "failed", "models" => [] }, JSON.parse(response.body))
    assert_not_includes response.body, "provider token detail"
  end

  test "an Owner gets a no-store form without a previously saved key" do
    sign_in_as users(:owner)

    with_gateway(@gateway) do
      get edit_workspace_provider_connection_path(@workspace, "codex")
    end

    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "no-cache", response.headers["Pragma"]
    assert_select "h1", "Edit Codex"
    assert_select "input[name='provider_connection[api_key]'][value='']"
    assert_select "input[name='provider_connection[model]'][value=?]", "gpt-5.6"
    assert_select "[data-provider-form-target='modelLabel']", text: "Model ID"
    assert_select "[data-provider-form-target='modelHint']", text: /Save without a model to load live choices/
    assert_select "[data-provider-form-target='apiKeyHint']", text: /Leave this blank to keep it/
    assert_select "[data-provider-form-target='executionField'][hidden]", count: 1
    assert_select "select[name='provider_connection[execution_mode]'] option", text: "Bounded HTTPS"
    assert_select "select[name='provider_connection[execution_mode]'] option[value='bounded']"
    assert_select "select[name='provider_connection[execution_mode]'][disabled]", count: 0
    assert_select "[data-provider-form-target='modelRefresh'].button-compact", text: "Refresh models"
    assert_select "[data-provider-form-target='modelState'][aria-live='polite']"
    assert_select "select[data-provider-form-target='discoveredModels'][name='provider_connection[model]'][disabled]", count: 1
    discovery = css_select("[data-provider-form-target='modelDiscovery']").sole
    assert_equal models_workspace_provider_connections_path(@workspace), discovery["data-models-url"]
    assert_equal "api_key", discovery["data-saved-auth-mode"]
    assert_equal "bounded", discovery["data-saved-execution-mode"]
    assert_not_includes discovery.attributes.keys, "data-api-key"
    assert_operator response.body.index('id="provider_connection_api_key"'), :<, response.body.index('id="provider_connection_model"')
    assert_includes response.body, "Leave this blank to keep it"
    assert_not_includes response.body, "field is the authority"
    assert_not_includes response.body, "Live guidance"
    assert_includes response.body, "Save settings"
    assert_includes response.body, "Save and test"
    assert_not_includes response.body, "saved-provider-secret"
  end

  test "the add form offers only providers that are not already connected" do
    sign_in_as users(:owner)

    with_gateway(@gateway) do
      get new_workspace_provider_connection_path(@workspace)
    end

    assert_response :success
    assert_select "select[name='provider_connection[adapter_key]'] option", count: 1
    assert_select "select[name='provider_connection[adapter_key]'] option", text: "Claude"
    assert_select "select[name='provider_connection[adapter_key]'] option[data-model-required='true'][data-secret-configured='false'][data-description=?]", "Connect Claude to this workspace."
    assert_select "h1", "Add a provider"
    assert_select "input[type='submit'][value='Save settings']"
    assert_select "input[type='submit'][value='Save and test']"
    assert_select "[data-provider-form-target='modelLabel']", text: "Model ID"
    assert_select "[data-provider-form-target='modelHint']", text: /Save without a model to load live choices/
    assert_select "input[name='provider_connection[model]'][required]", count: 0
    assert_select "input[name='provider_connection[model]'][data-model-required='true']", count: 1
    assert_select "[data-provider-form-target='apiKeyHint']", text: /Stored encrypted on this self-hosted deployment and never shown again/
    assert_select "[data-provider-form-target='executionField'][hidden]", count: 1
    assert_select "select[name='provider_connection[execution_mode]'][disabled]", count: 0
    assert_select "select[name='provider_connection[execution_mode]'] option[value='strong_isolated']"
    assert_select "select[name='provider_connection[execution_mode]'] option[value='bounded']", count: 0
    assert_select ".field-hint", text: /model ID/
    assert_includes response.body, "Save without a model to load live choices"
    assert_not_includes response.body, "data-models-url"
  end

  test "a subscription form shows its required execution boundary selector" do
    sign_in_as users(:owner)
    gateway = FakeProviderGateway.new([
      provider(
        adapter_key: "codex", name: "Codex", configured: true, secret_configured: true,
        auth_mode: "subscription", model: "gpt-5.6"
      ).merge("model_required" => false, "execution_mode" => "strong_isolated")
    ])

    with_gateway(gateway) do
      get edit_workspace_provider_connection_path(@workspace, "codex")
    end

    assert_response :success
    execution_field = css_select("[data-provider-form-target='executionField']").sole
    assert_not_includes execution_field.attributes.keys, "hidden"
    assert_select "select[name='provider_connection[execution_mode]'][required]", count: 1
    assert_select "select[name='provider_connection[execution_mode]'] option[value='strong_isolated'][selected]", count: 1
    assert_select "select[name='provider_connection[execution_mode]'] option[value='bounded']", count: 0
  end

  test "the add page explains when every supported provider is already connected" do
    sign_in_as users(:owner)
    catalog = provider_catalog.map do |provider|
      provider.merge("configured" => true, "secret_configured" => true, "auth_mode" => "api_key", "model" => "configured-model")
    end
    gateway = FakeProviderGateway.new(catalog)

    with_gateway(gateway) do
      get new_workspace_provider_connection_path(@workspace)
    end

    assert_response :success
    assert_select "h2", "All supported providers are connected"
    assert_select "a[href='#{workspace_runtime_installations_path(@workspace)}']", text: "Manage providers"
    assert_not_includes response.body, "Provider options are temporarily unavailable"
  end

  test "runner setup failures do not blame provider credentials" do
    sign_in_as users(:owner)

    with_gateway(-> { raise RunnerClient::ClientConfigurationError, "runner shared secret must contain at least 32 bytes" }) do
      get new_workspace_provider_connection_path(@workspace)
    end

    assert_redirected_to workspace_runtime_installations_path(@workspace)
    assert_equal "The provider service is not configured. Start the runner, then try again.", flash[:alert]
  end

  test "an Owner configures a provider through the runner and never persists the key" do
    sign_in_as users(:owner)

    with_gateway(@gateway) do
      post workspace_provider_connections_path(@workspace), params: {
        provider_connection: {
          adapter_key: "claude", auth_mode: "api_key", model: "claude-sonnet-4-5",
          api_key: "provider-secret-value"
        }
      }
    end

    assert_redirected_to workspace_runtime_installations_path(@workspace)
    assert_equal "Claude settings were saved. The connection test is not ready: the runner does not currently report a compatible runtime for this provider.", flash[:notice]
    assert_equal "provider-secret-value", @gateway.configure_calls.sole.fetch(:api_key)
    assert_equal "bounded", @gateway.configure_calls.sole.fetch(:execution_mode)
    event = @workspace.audit_events.find_by!(action: "runtime.provider_configured")
    assert_equal "runtime.provider_configured", event.action
    assert_equal({}, event.metadata)
    assert_not_includes response.body, "provider-secret-value"
  end

  test "an initial API-key setup can save without a model and continues in edit" do
    sign_in_as users(:owner)

    with_gateway(@gateway) do
      post workspace_provider_connections_path(@workspace), params: {
        provider_connection: {
          adapter_key: "claude", auth_mode: "api_key", model: "", api_key: "provider-secret-value"
        }
      }
      assert_redirected_to edit_workspace_provider_connection_path(@workspace, "claude")
      assert_equal "Claude settings were saved. Choose a model to continue.", flash[:notice]
      get edit_workspace_provider_connection_path(@workspace, "claude")
    end

    assert_response :success
    assert_equal "provider-secret-value", @gateway.configure_calls.sole.fetch(:api_key)
    assert_select "input[name='provider_connection[model]'][value='']"
    assert_select "[data-provider-form-target='modelDiscovery'][data-models-url]", count: 1
  end

  test "Save and test with a blank required model saves without running a test" do
    sign_in_as users(:owner)

    with_gateway(@gateway) do
      post workspace_provider_connections_path(@workspace), params: {
        commit: "Save and test",
        provider_connection: {
          adapter_key: "claude", auth_mode: "api_key", execution_mode: "bounded", model: "",
          api_key: "provider-secret-value"
        }
      }
    end

    assert_redirected_to edit_workspace_provider_connection_path(@workspace, "claude")
    assert_equal "Claude settings were saved. The connection test was not run: choose a model in Edit settings first.", flash[:notice]
    assert_empty @gateway.test_calls
  end

  test "a key-only setup can save an exact model on the next edit" do
    sign_in_as users(:owner)

    with_gateway(@gateway) do
      post workspace_provider_connections_path(@workspace), params: {
        provider_connection: {
          adapter_key: "claude", auth_mode: "api_key", model: "", api_key: "provider-secret-value"
        }
      }
      assert_redirected_to edit_workspace_provider_connection_path(@workspace, "claude")

      patch workspace_provider_connection_path(@workspace, "claude"), params: {
        provider_connection: {
          adapter_key: "claude", auth_mode: "api_key", model: "claude-sonnet-4-5", api_key: ""
        }
      }
    end

    assert_redirected_to workspace_runtime_installations_path(@workspace)
    assert_equal 2, @gateway.configure_calls.size
    assert_equal "", @gateway.configure_calls.last.fetch(:api_key)
    assert_equal "claude-sonnet-4-5", @gateway.configure_calls.last.fetch(:model)
  end

  test "saving a model anchors the current transport installation" do
    installation = runtime_installations(:acme_scripted)
    installation.update!(
      adapter_key: "codex", executable_path: "/navishai/provider-api/codex",
      executable_version: "codex 1.0.0", effective_model: "gpt-5.6",
      account_metadata: { "authentication" => "api_key", "transport" => "built_in_https" },
      transport: "built_in_https",
      health_status: "available", checked_at: 1.hour.ago
    )
    missing = installation.dup
    missing.assign_attributes(
      detection_key: "e" * 64, health_status: "missing", checked_at: 1.minute.from_now,
      approved: false, approved_by_membership: nil, approved_by_user: nil, approved_at: nil,
      runtime_test_status: "untested", runtime_tested_at: nil, runtime_tested_configuration_fingerprint: nil,
      runtime_test_failure_code: nil, runtime_test_input_units: 0, runtime_test_output_units: 0,
      runtime_test_usage_observed: false
    )
    missing.save!
    original = RuntimeRegistry.method(:refresh!)
    RuntimeRegistry.define_singleton_method(:refresh!) { |**| [] }
    sign_in_as users(:owner)

    with_gateway(@gateway) do
      post workspace_provider_connections_path(@workspace), params: {
        provider_connection: {
          adapter_key: "codex", auth_mode: "api_key", model: "gpt-5.6", api_key: "provider-secret-value"
        }
      }
    end

    assert_redirected_to workspace_runtime_installations_path(@workspace, anchor: "runtime-#{installation.id}")
    assert_equal "Codex settings were saved. Test the connection before allowing workspace access.", flash[:notice]
  ensure
    RuntimeRegistry.define_singleton_method(:refresh!, original) if original
  end

  test "Save and test records a passing result only for the current installation" do
    installation = runtime_installations(:acme_scripted)
    installation.update!(
      adapter_key: "codex", executable_path: "/navishai/provider-api/codex",
      executable_version: "codex 1.0.0", effective_model: "gpt-5.6",
      account_metadata: { "authentication" => "api_key", "transport" => "built_in_https" },
      transport: "built_in_https", execution_mode: "bounded", health_status: "available",
      compatibility_status: "compatible", checked_at: 1.hour.ago
    )
    @gateway.test_result = {
      "status" => "passed", "failure_code" => nil, "tested_at" => "2026-08-31T12:00:00Z",
      "configuration_fingerprint" => installation.configuration_fingerprint,
      "execution_mode" => "bounded", "effective_model" => "gpt-5.6",
      "usage_observed" => false, "input_units" => 0, "output_units" => 0
    }
    original = RuntimeRegistry.method(:refresh!)
    RuntimeRegistry.define_singleton_method(:refresh!) { |**| [] }
    sign_in_as users(:owner)

    with_gateway(@gateway) do
      post workspace_provider_connections_path(@workspace), params: {
        commit: "Save and test",
        provider_connection: {
          adapter_key: "codex", auth_mode: "api_key", execution_mode: "bounded",
          model: "gpt-5.6", api_key: "provider-secret-value"
        }
      }
    end

    assert_redirected_to workspace_runtime_installations_path(@workspace, anchor: "runtime-#{installation.id}")
    assert_equal "Codex settings were saved and the connection test passed.", flash[:notice]
    assert_equal 1, @gateway.test_calls.size
    assert_equal "passed", installation.reload.runtime_test_status
  ensure
    RuntimeRegistry.define_singleton_method(:refresh!, original) if original
  end

  test "Save and test saves settings without claiming a test when no runtime is current" do
    sign_in_as users(:owner)

    with_gateway(@gateway) do
      post workspace_provider_connections_path(@workspace), params: {
        commit: "Save and test",
        provider_connection: {
          adapter_key: "claude", auth_mode: "api_key", execution_mode: "bounded",
          model: "claude-sonnet-4-5", api_key: "provider-secret-value"
        }
      }
    end

    assert_redirected_to workspace_runtime_installations_path(@workspace)
    assert_equal "Claude settings were saved. The connection test was not run: the runner does not currently report a compatible runtime for this provider.", flash[:notice]
    assert_empty @gateway.test_calls
  end

  test "Save and test reports cleared evidence when the new test errors" do
    installation = runtime_installations(:acme_scripted)
    installation.update!(
      adapter_key: "codex", executable_path: "/navishai/provider-api/codex",
      executable_version: "codex 1.0.0", effective_model: "gpt-5.6",
      account_metadata: { "authentication" => "api_key", "transport" => "built_in_https" },
      transport: "built_in_https", execution_mode: "bounded", health_status: "available",
      compatibility_status: "compatible", checked_at: 1.hour.ago,
      approved: true, approved_by_membership: memberships(:owner_support),
      approved_by_user: users(:owner), approved_at: Time.current,
      runtime_test_status: "passed", runtime_tested_at: Time.current,
      runtime_tested_configuration_fingerprint: installation.configuration_fingerprint
    )
    @gateway.test_error = RunnerClient::Unavailable.new("offline")
    original = RuntimeRegistry.method(:refresh!)
    RuntimeRegistry.define_singleton_method(:refresh!) { |**| [] }
    sign_in_as users(:owner)

    with_gateway(@gateway) do
      post workspace_provider_connections_path(@workspace), params: {
        commit: "Save and test",
        provider_connection: {
          adapter_key: "codex", auth_mode: "api_key", execution_mode: "bounded",
          model: "gpt-5.6", api_key: "provider-secret-value"
        }
      }
    end

    assert_redirected_to workspace_runtime_installations_path(@workspace, anchor: "runtime-#{installation.id}")
    assert_equal "Codex settings were saved. Prior approval and test evidence were cleared; the new connection test failed. Workspace access remains disabled until a successful test is recorded.", flash[:alert]
    installation.reload
    assert_not installation.approved?
    assert_equal "untested", installation.runtime_test_status
    assert_nil installation.runtime_tested_configuration_fingerprint
    assert_equal 1, @gateway.test_calls.size
  ensure
    RuntimeRegistry.define_singleton_method(:refresh!, original) if original
  end

  test "saving a model does not anchor a stale runtime with mismatched version" do
    installation = runtime_installations(:acme_scripted)
    installation.update!(
      adapter_key: "codex", executable_path: "/navishai/provider-api/codex",
      executable_version: "codex stale", effective_model: "gpt-5.6",
      account_metadata: { "authentication" => "api_key", "transport" => "built_in_https" }
    )
    original = RuntimeRegistry.method(:refresh!)
    RuntimeRegistry.define_singleton_method(:refresh!) { |**| [] }
    sign_in_as users(:owner)

    with_gateway(@gateway) do
      post workspace_provider_connections_path(@workspace), params: {
        provider_connection: {
          adapter_key: "codex", auth_mode: "api_key", model: "gpt-5.6", api_key: "provider-secret-value"
        }
      }
    end

    assert_redirected_to workspace_runtime_installations_path(@workspace)
    assert_equal "Codex settings were saved. The connection test is not ready: the runner does not currently report a compatible runtime for this provider.", flash[:notice]
  ensure
    RuntimeRegistry.define_singleton_method(:refresh!, original) if original
  end

  test "subscription configuration does not require an API key parameter" do
    sign_in_as users(:owner)

    with_gateway(@gateway) do
      post workspace_provider_connections_path(@workspace), params: {
        provider_connection: {
          adapter_key: "claude", auth_mode: "subscription", execution_mode: "strong_isolated", model: "claude-sonnet-4-5"
        }
      }
    end

    assert_redirected_to workspace_runtime_installations_path(@workspace)
    assert_equal "", @gateway.configure_calls.sole.fetch(:api_key)
    assert_equal "strong_isolated", @gateway.configure_calls.sole.fetch(:execution_mode)
  end

  test "subscription configuration can save credentials before model discovery" do
    sign_in_as users(:owner)

    with_gateway(@gateway) do
      post workspace_provider_connections_path(@workspace), params: {
        provider_connection: {
          adapter_key: "claude", auth_mode: "subscription", execution_mode: "strong_isolated", model: "", api_key: ""
        }
      }
    end

    assert_redirected_to edit_workspace_provider_connection_path(@workspace, "claude")
    assert_equal "Claude settings were saved. Choose a model to continue.", flash[:notice]
    assert_equal "", @gateway.configure_calls.sole.fetch(:api_key)
    assert_equal "", @gateway.configure_calls.sole.fetch(:model)
    assert_equal "strong_isolated", @gateway.configure_calls.sole.fetch(:execution_mode)
  end

  test "editing a configured provider can clear its model for rediscovery" do
    sign_in_as users(:owner)

    with_gateway(@gateway) do
      patch workspace_provider_connection_path(@workspace, "codex"), params: {
        provider_connection: { adapter_key: "codex", auth_mode: "api_key", model: "", api_key: "" }
      }
    end

    assert_redirected_to edit_workspace_provider_connection_path(@workspace, "codex")
    assert_equal "Codex settings were saved. Choose a model to continue.", flash[:notice]
    assert_equal "", @gateway.configure_calls.sole.fetch(:model)
    assert_equal "bounded", @gateway.configure_calls.sole.fetch(:execution_mode)
  end

  test "blank API key on edit means keep the runner secret" do
    sign_in_as users(:owner)

    with_gateway(@gateway) do
      patch workspace_provider_connection_path(@workspace, "codex"), params: {
        provider_connection: { adapter_key: "codex", auth_mode: "api_key", model: "gpt-5.6", api_key: "" }
      }
    end

    assert_redirected_to workspace_runtime_installations_path(@workspace)
    assert_equal "", @gateway.configure_calls.sole.fetch(:api_key)
  end

  test "a confirmed configuration redirects when local invalidation fails" do
    sign_in_as users(:owner)
    original = RuntimeRegistry.method(:invalidate_adapter!)
    RuntimeRegistry.define_singleton_method(:invalidate_adapter!) do |**|
      raise RuntimeRegistry::InvalidPolicy, "local invalidation failed"
    end

    with_gateway(@gateway) do
      post workspace_provider_connections_path(@workspace), params: {
        provider_connection: {
          adapter_key: "claude", auth_mode: "api_key", model: "claude-sonnet-4-5", api_key: "provider-secret-value"
        }
      }
    end

    assert_redirected_to workspace_runtime_installations_path(@workspace)
    assert_equal "The provider change was confirmed and saved, but local status could not be refreshed. Refresh status again.", flash[:alert]
    assert_nil flash[:notice]
    assert_equal "provider-secret-value", @gateway.configure_calls.sole.fetch(:api_key)
  ensure
    RuntimeRegistry.define_singleton_method(:invalidate_adapter!, original)
  end

  test "a confirmed removal redirects when local invalidation fails" do
    sign_in_as users(:owner)
    original = RuntimeRegistry.method(:invalidate_adapter!)
    RuntimeRegistry.define_singleton_method(:invalidate_adapter!) do |**|
      raise RuntimeRegistry::InvalidPolicy, "local invalidation failed"
    end

    with_gateway(@gateway) do
      delete workspace_provider_connection_path(@workspace, "codex")
    end

    assert_redirected_to workspace_runtime_installations_path(@workspace)
    assert_equal "The provider change was confirmed and saved, but local status could not be refreshed. Refresh status again.", flash[:alert]
    assert_nil flash[:notice]
    assert_equal [ "codex" ], @gateway.remove_calls
  ensure
    RuntimeRegistry.define_singleton_method(:invalidate_adapter!, original)
  end

  test "a confirmed configuration uses the confirmed-change alert when local refresh fails" do
    sign_in_as users(:owner)
    @gateway.detect_error = ActiveRecord::StatementInvalid.new("local status refresh failed")

    with_gateway(@gateway) do
      post workspace_provider_connections_path(@workspace), params: {
        provider_connection: {
          adapter_key: "claude", auth_mode: "api_key", model: "claude-sonnet-4-5", api_key: "provider-secret-value"
        }
      }
    end

    assert_redirected_to workspace_runtime_installations_path(@workspace)
    assert_equal "The provider change was confirmed and saved, but local status could not be refreshed. Refresh status again.", flash[:alert]
    assert_nil flash[:notice]
  end

  test "an Owner removes a provider through the runner" do
    sign_in_as users(:owner)

    with_gateway(@gateway) do
      delete workspace_provider_connection_path(@workspace, "codex")
    end

    assert_redirected_to workspace_runtime_installations_path(@workspace)
    assert_equal [ "codex" ], @gateway.remove_calls
    assert @workspace.audit_events.exists?(action: "runtime.provider_removed")
  end

  test "a confirmed configuration revokes stale approval and is audited before a failed refresh" do
    installation = approved_codex_installation
    @gateway.detect_error = RunnerClient::Unavailable.new("offline")
    sign_in_as users(:owner)

    with_gateway(@gateway) do
      patch workspace_provider_connection_path(@workspace, "codex"), params: {
        provider_connection: { adapter_key: "codex", auth_mode: "api_key", model: "gpt-5.6", api_key: "" }
      }
    end

    assert_redirected_to workspace_runtime_installations_path(@workspace)
    assert_equal "The provider change was confirmed and saved, but local status could not be refreshed. Refresh status again.", flash[:alert]
    installation.reload
    refute installation.approved?
    assert_equal "untested", installation.runtime_test_status
    assert_nil installation.runtime_tested_configuration_fingerprint
    actions = @workspace.audit_events.order(:id).last(2).map(&:action)
    assert_equal %w[runtime.installation_revoked runtime.provider_configured], actions
  end

  test "a confirmed removal revokes stale approval and is audited before a failed refresh" do
    installation = approved_codex_installation
    @gateway.detect_error = RunnerClient::Unavailable.new("offline")
    sign_in_as users(:owner)

    with_gateway(@gateway) do
      delete workspace_provider_connection_path(@workspace, "codex")
    end

    assert_redirected_to workspace_runtime_installations_path(@workspace)
    assert_equal "The provider change was confirmed and saved, but local status could not be refreshed. Refresh status again.", flash[:alert]
    installation.reload
    refute installation.approved?
    assert_equal "untested", installation.runtime_test_status
    actions = @workspace.audit_events.order(:id).last(2).map(&:action)
    assert_equal %w[runtime.installation_revoked runtime.provider_removed], actions
  end

  private
    def with_gateway(gateway)
      original = ProviderConnectionGateway.method(:new)
      ProviderConnectionGateway.define_singleton_method(:new) do |*|
        gateway.respond_to?(:call) ? gateway.call : gateway
      end
      yield
    ensure
      ProviderConnectionGateway.define_singleton_method(:new, original)
    end

    def provider_catalog
      [
        provider(
          adapter_key: "codex", name: "Codex", configured: true, secret_configured: true,
          auth_mode: "api_key", model: "gpt-5.6"
        ),
        provider(
          adapter_key: "claude", name: "Claude", configured: false, secret_configured: false,
          auth_mode: "", model: ""
        )
      ]
    end

    def provider(adapter_key:, name:, configured:, secret_configured:, auth_mode:, model:)
      {
        "adapter_key" => adapter_key, "name" => name, "description" => "Connect #{name} to this workspace.",
        "auth_modes" => %w[api_key subscription], "model_required" => true, "configured" => configured,
        "secret_configured" => secret_configured, "auth_mode" => auth_mode, "model" => model,
        "supported_execution_modes" => %w[bounded host_trusted strong_isolated],
        "execution_mode" => configured ? (auth_mode == "api_key" ? "bounded" : "strong_isolated") : "",
        "health_status" => configured ? "available" : "not_configured", "available" => true,
        "unavailable_reason" => "",
        "executable_version" => "#{name.downcase} 1.0.0"
      }
    end

    def approved_codex_installation
      installation = runtime_installations(:acme_scripted)
      installation.update!(
        adapter_key: "codex", runtime_test_status: "passed", runtime_tested_at: Time.current,
        runtime_tested_configuration_fingerprint: installation.configuration_fingerprint,
        approved: true, approved_by_membership: memberships(:owner_support),
        approved_by_user: users(:owner), approved_at: Time.current
      )
      installation
    end

    class FakeProviderGateway
      attr_accessor :detect_error, :models_error, :models_result, :test_error, :test_result
      attr_reader :configure_calls, :remove_calls, :models_calls, :test_calls

      def initialize(catalog)
        @catalog = catalog
        @configure_calls = []
        @remove_calls = []
        @models_calls = []
        @test_calls = []
        @models_result = { "status" => "unsupported", "checked_at" => "2026-08-31T12:00:00Z", "models" => [] }
      end

      def catalog(workspace_key:)
        @catalog
      end

      def configure(**attributes)
        @configure_calls << attributes
        provider = @catalog.find { |item| item.fetch("adapter_key") == attributes.fetch(:adapter_key) }
        provider.merge!(
          "configured" => true, "secret_configured" => attributes.fetch(:api_key).present? || provider.fetch("secret_configured"),
          "auth_mode" => attributes.fetch(:auth_mode), "execution_mode" => attributes.fetch(:execution_mode),
          "model" => attributes.fetch(:model), "health_status" => "available", "available" => true,
          "unavailable_reason" => ""
        )
        provider
      end

      def models(workspace_key:, adapter_key:, execution_mode:)
        @models_calls << [ workspace_key, adapter_key, execution_mode ]
        raise models_error if models_error

        models_result
      end

      def remove(workspace_key:, request_id:, adapter_key:)
        @remove_calls << adapter_key
        @catalog.find { |item| item.fetch("adapter_key") == adapter_key }.merge(
          "configured" => false, "secret_configured" => false, "auth_mode" => "", "model" => "",
          "execution_mode" => "", "health_status" => "not_configured", "unavailable_reason" => ""
        )
      end

      def detect_runtimes!(workspace_key:)
        raise detect_error if detect_error

        []
      end

      def test_runtime!(workspace_key:, request_id:, detection_key:, execution_mode:, configuration_fingerprint:)
        @test_calls << [ workspace_key, request_id, detection_key, execution_mode, configuration_fingerprint ]
        raise test_error if test_error

        test_result || raise("test result was not configured")
      end
    end
end
