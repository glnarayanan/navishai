require "test_helper"

class WorkspaceInvitationsControllerTest < ActionDispatch::IntegrationTest
  test "owner can invite an admin" do
    sign_in_as users(:owner)

    assert_difference "AuditEvent.count", 1 do
      assert_enqueued_emails 1 do
        post workspace_workspace_invitations_path(workspaces(:acme_support)), params: {
          workspace_invitation: { email_address: "admin@example.com", role: "admin" }
        }
      end
    end

    assert_redirected_to workspace_workspace_invitations_path(workspaces(:acme_support))
    assert_equal "admin", WorkspaceInvitation.find_by!(email_address: "admin@example.com").role
    event = AuditEvent.order(:id).last
    assert_equal "workspace_invitation.created", event.action
    assert_equal users(:owner), event.actor
    assert_equal workspaces(:acme_support), event.workspace
  end

  test "manager cannot invite" do
    sign_in_as users(:teammate)

    assert_no_difference [ "WorkspaceInvitation.count", "AuditEvent.count" ] do
      post workspace_workspace_invitations_path(workspaces(:acme_success)), params: {
        workspace_invitation: { email_address: "member@example.com", role: "member" }
      }
    end

    assert_response :forbidden
  end

  test "cannot revoke an invitation in another workspace" do
    sign_in_as users(:outsider)

    delete workspace_workspace_invitation_path(
      workspaces(:beta_support),
      workspace_invitations(:pending_member)
    )

    assert_response :not_found
    assert workspace_invitations(:pending_member).reload.pending?
  end
end
