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
    end
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
    assert_includes response.body, "Leave this blank to keep it"
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
    assert_select "h1", "Add a provider"
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
    assert_equal "provider-secret-value", @gateway.configure_calls.sole.fetch(:api_key)
    event = @workspace.audit_events.find_by!(action: "runtime.provider_configured")
    assert_equal "runtime.provider_configured", event.action
    assert_equal({}, event.metadata)
    assert_not_includes response.body, "provider-secret-value"
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
    assert_equal "The provider change was saved, but its status could not be refreshed. Refresh status again.", flash[:alert]
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
    assert_equal "The provider change was saved, but its status could not be refreshed. Refresh status again.", flash[:alert]
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
        "health_status" => configured ? "available" : "not_configured", "available" => true,
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
      attr_accessor :detect_error
      attr_reader :configure_calls, :remove_calls

      def initialize(catalog)
        @catalog = catalog
        @configure_calls = []
        @remove_calls = []
      end

      def catalog(workspace_key:)
        @catalog
      end

      def configure(**attributes)
        @configure_calls << attributes
        provider = @catalog.find { |item| item.fetch("adapter_key") == attributes.fetch(:adapter_key) }
        provider.merge(
          "configured" => true, "secret_configured" => attributes.fetch(:api_key).present? || provider.fetch("secret_configured"),
          "auth_mode" => attributes.fetch(:auth_mode), "model" => attributes.fetch(:model), "health_status" => "available"
        )
      end

      def remove(workspace_key:, request_id:, adapter_key:)
        @remove_calls << adapter_key
        @catalog.find { |item| item.fetch("adapter_key") == adapter_key }.merge(
          "configured" => false, "secret_configured" => false, "auth_mode" => "", "model" => "",
          "health_status" => "not_configured"
        )
      end

      def detect_runtimes!(workspace_key:)
        raise detect_error if detect_error

        []
      end
    end
end
