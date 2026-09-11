require "test_helper"

class FirstOwnerBootstrapTest < ActiveSupport::TestCase
  setup do
    @original_token = ENV["NAVISHAI_BOOTSTRAP_TOKEN"]
    @original_expiry = ENV["NAVISHAI_BOOTSTRAP_TOKEN_EXPIRES_AT"]
    ENV["NAVISHAI_BOOTSTRAP_TOKEN"] = "b" * 32
    ENV["NAVISHAI_BOOTSTRAP_TOKEN_EXPIRES_AT"] = 1.hour.from_now.iso8601
    InstallationState.delete_all
    WorkspaceInvitation.delete_all
    Session.delete_all
    IdentityMatchCandidate.delete_all
    SourceIdentityKey.delete_all
    SourceIdentity.delete_all
    ContactMerge.delete_all
    AccountMerge.delete_all
    Contact.delete_all
    Account.delete_all
    Membership.delete_all
    Workspace.delete_all
    Organization.delete_all
    User.delete_all
  end

  teardown do
    ENV["NAVISHAI_BOOTSTRAP_TOKEN"] = @original_token
    ENV["NAVISHAI_BOOTSTRAP_TOKEN_EXPIRES_AT"] = @original_expiry
  end

  test "requires an unexpired deployment token" do
    assert FirstOwnerBootstrap.available?
    assert FirstOwnerBootstrap.valid_token?("b" * 32)

    ENV["NAVISHAI_BOOTSTRAP_TOKEN_EXPIRES_AT"] = 1.second.ago.iso8601

    assert_not FirstOwnerBootstrap.available?
    assert_not FirstOwnerBootstrap.valid_token?("b" * 32)
  end

  test "stays renewable only until the first Owner exists" do
    ENV["NAVISHAI_BOOTSTRAP_TOKEN_EXPIRES_AT"] = 1.second.ago.iso8601
    assert FirstOwnerBootstrap.renewable?
    assert_not FirstOwnerBootstrap.available?

    Organization.create!(name: "Existing", slug: "existing")

    assert_not FirstOwnerBootstrap.renewable?
  end

  test "fails closed when token expiry is missing or malformed" do
    ENV.delete("NAVISHAI_BOOTSTRAP_TOKEN_EXPIRES_AT")
    assert_not FirstOwnerBootstrap.available?

    ENV["NAVISHAI_BOOTSTRAP_TOKEN_EXPIRES_AT"] = "not-a-time"
    assert_not FirstOwnerBootstrap.available?
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
