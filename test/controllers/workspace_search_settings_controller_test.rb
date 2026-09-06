require "test_helper"

class WorkspaceSearchSettingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:acme_support)
    @client = Object.new
    @client.define_singleton_method(:web_search_catalog!) do |**|
      { "provider_keys" => %w[searxng exa], "default_provider_key" => "searxng" }
    end
  end

  test "an Admin configures search without access to workspace identity" do
    @workspace.memberships.create!(user: users(:teammate), role: :admin)
    sign_in_as users(:teammate)
    with_runner_client(@client) do
      get edit_workspace_search_settings_path(@workspace)
      assert_response :success
      assert_select "select[name='workspace[web_search_provider_key]']"
      patch workspace_search_settings_path(@workspace), params: { workspace: { web_search_provider_key: "exa" } }
      assert_redirected_to edit_workspace_search_settings_path(@workspace)
    end
    assert_equal "exa", @workspace.reload.web_search_provider_key
    assert AuditEvent.where(action: "workspace.search_provider_updated", workspace: @workspace, actor: users(:teammate)).exists?
    get edit_workspace_path(@workspace)
    assert_response :forbidden
  end

  test "unknown providers and catalog failure preserve the saved provider" do
    sign_in_as users(:owner)
    @workspace.update!(web_search_provider_key: "exa")
    with_runner_client(@client) do
      patch workspace_search_settings_path(@workspace), params: { workspace: { web_search_provider_key: "unapproved" } }
      assert_response :unprocessable_content
    end
    assert_equal "exa", @workspace.reload.web_search_provider_key
    @client.define_singleton_method(:web_search_catalog!) { |**| raise RunnerClient::Unavailable }
    with_runner_client(@client) do
      get edit_workspace_search_settings_path(@workspace)
      assert_response :success
      assert_select "[role=alert]", text: /saved choice has been preserved/
      assert_select "select", count: 0
      patch workspace_search_settings_path(@workspace), params: { workspace: { web_search_provider_key: "" } }
      assert_response :service_unavailable
    end
    assert_equal "exa", @workspace.reload.web_search_provider_key
  end

  test "members and other workspaces cannot change the provider" do
    @workspace.memberships.create!(user: users(:teammate), role: :member)
    sign_in_as users(:teammate)
    get edit_workspace_search_settings_path(@workspace)
    assert_response :forbidden
    patch workspace_search_settings_path(@workspace), params: { workspace: { web_search_provider_key: "exa" } }
    assert_response :forbidden
    patch workspace_search_settings_path(workspaces(:beta_support)), params: { workspace: { web_search_provider_key: "exa" } }
    assert_response :not_found
  end
  private
    def with_runner_client(client)
      original = RunnerClient.method(:new)
      RunnerClient.define_singleton_method(:new) { client }
      yield
    ensure
      RunnerClient.define_singleton_method(:new, original)
    end
end
