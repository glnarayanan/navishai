require "test_helper"

class UsageRatesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
    sign_in_as @owner.user
  end

  test "renders the honest no-rate state and lets an Owner publish a version" do
    get workspace_usage_rates_path(@workspace)

    assert_response :success
    assert_select "h1", "Usage and rates"
    assert_select ".usage-rate-editor"
    assert_select ".usage-rate-current", text: /unavailable rather than zero/

    assert_difference [ "UsageRateVersion.count", "AuditEvent.count" ], 1 do
      post workspace_usage_rates_path(@workspace), params: { usage_rate: rate_params }
    end

    assert_redirected_to workspace_usage_rates_path(@workspace)
    follow_redirect!
    assert_response :success
    assert_select ".usage-rate-current", text: /v1/
    assert_select ".usage-rate-current", text: /USD/
    assert_select ".usage-rate-version", text: /Admin-entered public rate card/
  end

  test "an Admin can publish and roll back only this Workspace's versions" do
    admin = create_membership(:admin, "usage-admin@example.com")
    sign_in_as admin.user
    post workspace_usage_rates_path(@workspace), params: { usage_rate: rate_params }
    first = @workspace.reload.usage_rate_setting.current_version
    post workspace_usage_rates_path(@workspace), params: {
      usage_rate: rate_params.merge(expected_current_version_id: first.id, input_rate: "4")
    }
    second = @workspace.reload.usage_rate_setting.current_version

    post rollback_workspace_usage_rates_path(@workspace), params: {
      version_id: first.id, expected_current_version_id: second.id
    }

    assert_redirected_to workspace_usage_rates_path(@workspace)
    assert_equal first, @workspace.reload.usage_rate_setting.current_version

    foreign_workspace = workspaces(:beta_support)
    foreign_admin = foreign_workspace.memberships.create!(user: users(:teammate), role: :admin)
    foreign = UsageRateConfiguration.publish!(
      workspace: foreign_workspace, membership: foreign_admin,
      attributes: rate_params.merge(expected_current_version_id: nil)
    )
    post rollback_workspace_usage_rates_path(@workspace), params: {
      version_id: foreign.id, expected_current_version_id: first.id
    }
    assert_response :not_found
  end

  test "members can inspect rates but cannot change them" do
    member = create_membership(:member, "usage-member@example.com")
    sign_in_as member.user

    get workspace_usage_rates_path(@workspace)
    assert_response :success
    assert_select ".usage-rate-editor", count: 0

    assert_no_difference "UsageRateVersion.count" do
      post workspace_usage_rates_path(@workspace), params: { usage_rate: rate_params }
    end
    assert_response :forbidden
    assert_select "h1", "You can’t change usage rates"
    assert_select "a", "Back to usage rates"

    assert_no_difference "UsageRateVersion.count" do
      post rollback_workspace_usage_rates_path(@workspace), params: {
        version_id: 1, expected_current_version_id: ""
      }
    end
    assert_response :forbidden
  end

  test "invalid rates render the real page without publishing" do
    post workspace_usage_rates_path(@workspace), params: {
      usage_rate: rate_params.merge(currency: "US", input_rate: "")
    }

    assert_response :unprocessable_content
    assert_select "h1", "Usage and rates"
    assert_select "[role=alert]", text: /Currency must be a three-letter code/
    assert_select "input[name='usage_rate[currency]'][value='US']"
    assert_nil @workspace.reload.usage_rate_setting
  end

  private
    def create_membership(role, email)
      user = User.create!(email_address: email, password: "password12345", verified_at: Time.current)
      @workspace.memberships.create!(user:, role:)
    end

    def rate_params
      {
        expected_current_version_id: nil, currency: "USD",
        source_name: "Admin-entered public rate card",
        input_rate: "1", output_rate: "2", search_rate: "3"
      }
    end
end
