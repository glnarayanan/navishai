require "test_helper"

class WorkspaceInvitationAcceptancesControllerTest < ActionDispatch::IntegrationTest
  test "new user accepts an invitation and signs in" do
    invitation = workspace_invitations(:pending_member)
    token = invitation.generate_token_for(:acceptance)

    post workspace_invitation_acceptance_path(token), params: {
      password: "password12345",
      password_confirmation: "password12345"
    }

    assert_redirected_to root_path
    assert cookies[:session_id]
    assert invitation.reload.accepted?
  end

  test "signed-in user with another email cannot accept" do
    invitation = workspace_invitations(:pending_member)
    token = invitation.generate_token_for(:acceptance)
    sign_in_as users(:teammate)

    post workspace_invitation_acceptance_path(token)

    assert_redirected_to workspace_invitation_acceptance_path(token)
    assert invitation.reload.pending?
  end
end
