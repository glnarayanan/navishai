require "test_helper"

class FirstOwnerBootstrapTest < ActiveSupport::TestCase
  setup do
    InstallationState.delete_all
    WorkspaceInvitation.delete_all
    Session.delete_all
    Membership.delete_all
    Workspace.delete_all
    Organization.delete_all
    User.delete_all
  end

  test "creates the first verified owner atomically" do
    user = FirstOwnerBootstrap.call(
      organization_name: "New Org",
      organization_slug: "new-org",
      workspace_name: "Support",
      workspace_slug: "support",
      email_address: "owner@new.example",
      password: "password12345",
      password_confirmation: "password12345"
    )

    assert user.verified?
    assert_equal "owner", user.memberships.sole.role
    assert_equal "new-org", user.workspaces.sole.organization.slug
    assert InstallationState.exists?
  end

  test "stays closed after the bootstrapped records are removed" do
    user = FirstOwnerBootstrap.call(
      organization_name: "New Org",
      organization_slug: "new-org",
      workspace_name: "Support",
      workspace_slug: "support",
      email_address: "owner@new.example",
      password: "password12345",
      password_confirmation: "password12345"
    )
    Membership.where(user: user).delete_all
    user.destroy!
    Workspace.delete_all
    Organization.delete_all

    assert_raises(FirstOwnerBootstrap::Unavailable) do
      FirstOwnerBootstrap.call(
        organization_name: "Other",
        organization_slug: "other",
        workspace_name: "Other",
        workspace_slug: "other",
        email_address: "other@example.com",
        password: "password12345",
        password_confirmation: "password12345"
      )
    end
  end

  test "refuses a second bootstrap" do
    FirstOwnerBootstrap.call(
      organization_name: "New Org",
      organization_slug: "new-org",
      workspace_name: "Support",
      workspace_slug: "support",
      email_address: "owner@new.example",
      password: "password12345",
      password_confirmation: "password12345"
    )

    assert_raises(FirstOwnerBootstrap::Unavailable) do
      FirstOwnerBootstrap.call(
        organization_name: "Other",
        organization_slug: "other",
        workspace_name: "Other",
        workspace_slug: "other",
        email_address: "other@example.com",
        password: "password12345",
        password_confirmation: "password12345"
      )
    end
  end
end
