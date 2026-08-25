require "test_helper"

class SetupsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @original_token = ENV["NAVISHAI_BOOTSTRAP_TOKEN"]
    ENV["NAVISHAI_BOOTSTRAP_TOKEN"] = "b" * 32
    InstallationState.delete_all
    WorkspaceInvitation.delete_all
    Session.delete_all
    Membership.delete_all
    Workspace.delete_all
    Organization.delete_all
    User.delete_all
  end

  teardown do
    ENV["NAVISHAI_BOOTSTRAP_TOKEN"] = @original_token
  end

  test "shows first-run setup while bootstrap is available" do
    get new_setup_path

    assert_response :success
    assert_select "h1", text: "Create the first Owner"
  end

  test "valid deployment token creates and signs in the first Owner" do
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

    assert_redirected_to root_path
    assert cookies[:session_id]
    assert_equal "owner", User.find_by!(email_address: "owner@new.example").memberships.sole.role
    assert InstallationState.exists?
  end

  test "invalid deployment token creates nothing" do
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

    assert_redirected_to new_setup_path
    assert_not User.exists?
    assert_not InstallationState.exists?
  end
end
