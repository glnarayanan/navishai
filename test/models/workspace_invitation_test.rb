require "test_helper"

class WorkspaceInvitationTest < ActiveSupport::TestCase
  test "normalizes its email and rejects an existing member" do
    invitation = WorkspaceInvitation.new(
      workspace: workspaces(:acme_support),
      email_address: " OWNER@Example.com ",
      role: :member,
      status: :pending,
      invited_by: users(:owner)
    )

    assert_not invitation.valid?
    assert_equal "owner@example.com", invitation.email_address
    assert_includes invitation.errors[:email_address], "is already a workspace member"
  end

  test "accepts a new user once and verifies the email" do
    invitation = workspace_invitations(:pending_member)

    user = invitation.accept!(password: "password12345", password_confirmation: "password12345")

    assert user.verified?
    assert_equal "member", user.memberships.find_by!(workspace: invitation.workspace).role
    assert invitation.reload.accepted?
    assert_raises(WorkspaceInvitation::AcceptanceError) { invitation.accept!(user: user) }
  end

  test "requires an existing invited user to sign in" do
    User.create!(
      email_address: workspace_invitations(:pending_member).email_address,
      password: "password12345",
      password_confirmation: "password12345",
      verified_at: Time.current
    )

    assert_raises(WorkspaceInvitation::AuthenticationRequired) do
      workspace_invitations(:pending_member).accept!(password: "password12345", password_confirmation: "password12345")
    end
  end

  test "rejects a signed-in user with another email" do
    assert_raises(WorkspaceInvitation::AcceptanceError) do
      workspace_invitations(:pending_member).accept!(user: users(:teammate))
    end
  end

  test "revocation invalidates the acceptance token" do
    invitation = workspace_invitations(:pending_member)
    token = invitation.generate_token_for(:acceptance)

    invitation.revoke!

    assert_raises(ActiveSupport::MessageVerifier::InvalidSignature) do
      WorkspaceInvitation.find_by_token_for!(:acceptance, token)
    end
  end

  test "marks pending invitations as expired" do
    invitation = workspace_invitations(:pending_member)
    invitation.update_column(:expires_at, 1.minute.ago)

    WorkspaceInvitation.expire_pending!

    assert invitation.reload.expired?
  end
end
