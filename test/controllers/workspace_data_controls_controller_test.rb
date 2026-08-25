require "test_helper"

class WorkspaceDataControlsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:acme_support)
    @policy = @workspace.create_workspace_data_policy!
  end

  test "owner sees and updates separate content and audit retention" do
    sign_in_as users(:owner)

    get workspace_data_controls_path(@workspace)

    assert_response :success
    assert_select "h1", "Data controls"
    assert_select "select[name='workspace_data_policy[content_retention_days]']"
    assert_select "a", text: "Data"

    assert_difference "AuditEvent.count", 1 do
      patch workspace_data_controls_path(@workspace), params: {
        workspace_data_policy: { content_retention_days: "365", audit_retention_days: "2555" }
      }
    end

    assert_redirected_to workspace_data_controls_path(@workspace)
    assert_equal 365, @policy.reload.content_retention_days
    assert_equal 2555, @policy.audit_retention_days
    audit = AuditEvent.order(:id).last
    assert_equal "workspace.data_policy_updated", audit.action
    assert_equal users(:owner), audit.actor
    assert_equal({ "content_retention_days" => 365, "audit_retention_days" => 2555 }, audit.metadata)
  end

  test "audit retention cannot be shorter than content retention" do
    sign_in_as users(:owner)

    assert_no_difference "AuditEvent.count" do
      patch workspace_data_controls_path(@workspace), params: {
        workspace_data_policy: { content_retention_days: "1825", audit_retention_days: "365" }
      }
    end

    assert_response :unprocessable_content
    assert_select ".inline-error", text: /Audit retention days must be at least as long/
    assert_nil @policy.reload.content_retention_days
  end

  test "non-owners cannot inspect or change the policy" do
    membership = @workspace.memberships.create!(user: users(:teammate), role: :manager)
    sign_in_as membership.user

    get workspace_data_controls_path(@workspace)
    assert_response :forbidden

    assert_no_difference "AuditEvent.count" do
      patch workspace_data_controls_path(@workspace), params: {
        workspace_data_policy: { content_retention_days: "30", audit_retention_days: "365" }
      }
    end
    assert_response :forbidden

    get workspace_support_cases_path(@workspace)
    assert_select "a", { text: "Data", count: 0 }
  end
end
