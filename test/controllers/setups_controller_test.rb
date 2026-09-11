require "test_helper"

class SetupsControllerTest < ActionDispatch::IntegrationTest
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

  test "shows first-run setup while bootstrap is available" do
    get new_setup_path

    assert_response :success
    assert_select "h1", text: "Create the first Owner"
  end

  test "valid deployment token creates and signs in the first Owner" do
    assert_difference "AuditEvent.count", 1 do
      post setup_path, params: {
        bootstrap_token: "b" * 32,
        setup: {
          organization_name: "New Org",
          organization_slug: "new-org",
          workspace_name: "Support",
          workspace_slug: "support",
          email_address: "owner@new.example",
          password: "password12345",
          password_confirmation: "password12345"
        }
      }
    end

    assert_redirected_to root_path
    assert cookies[:session_id]
    owner = User.find_by!(email_address: "owner@new.example")
    assert_equal "owner", owner.memberships.sole.role
    assert InstallationState.exists?
    event = AuditEvent.order(:id).last
    assert_equal "installation.bootstrapped", event.action
    assert_equal owner, event.actor
    assert_equal owner.workspaces.sole, event.workspace
  end

  test "invalid deployment token creates nothing" do
    assert_no_difference "AuditEvent.count" do
      post setup_path, params: {
        bootstrap_token: "wrong",
        setup: {
          organization_name: "New Org",
          organization_slug: "new-org",
          workspace_name: "Support",
          workspace_slug: "support",
          email_address: "owner@new.example",
          password: "password12345",
          password_confirmation: "password12345"
        }
      }
    end

    assert_redirected_to new_setup_path
    assert_not User.exists?
    assert_not InstallationState.exists?
  end

  test "expired deployment token does not expose setup" do
    ENV["NAVISHAI_BOOTSTRAP_TOKEN_EXPIRES_AT"] = 1.second.ago.iso8601

    get new_setup_path

    assert_response :not_found
  end

  test "landing links to first-time setup while bootstrap is available" do
    get root_path

    assert_response :success
    assert_select "a[href=?]", new_setup_path, text: "First-time setup"
  end
end
