require "test_helper"

class WorkspaceInvitationAcceptancesControllerTest < ActionDispatch::IntegrationTest
  test "new user accepts an invitation and signs in" do
    invitation = workspace_invitations(:pending_member)
    token = invitation.generate_token_for(:acceptance)

    assert_difference "AuditEvent.count", 1 do
      post workspace_invitation_acceptance_path(token: token), params: {
        password: "password12345",
        password_confirmation: "password12345"
      }
    end

    assert_redirected_to root_path
    assert cookies[:session_id]
    assert invitation.reload.accepted?
    event = AuditEvent.order(:id).last
    assert_equal "workspace_invitation.accepted", event.action
    assert_equal invitation.workspace, event.workspace
    assert_equal({ "role" => invitation.role }, event.metadata)
  end

  test "signed-in user with another email cannot accept" do
    invitation = workspace_invitations(:pending_member)
    token = invitation.generate_token_for(:acceptance)
    sign_in_as users(:teammate)

    assert_no_difference "AuditEvent.count" do
      post workspace_invitation_acceptance_path(token: token)
    end

    assert_redirected_to workspace_invitation_acceptance_path(token: token)
    assert invitation.reload.pending?
  end
end
