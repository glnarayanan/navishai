require "test_helper"

class CurrentTest < ActiveSupport::TestCase
  teardown { Current.reset }

  test "allows a member to select a workspace" do
    Current.user = users(:owner)
    Current.workspace = workspaces(:acme_support)

    assert_equal workspaces(:acme_support), Current.require_workspace!
  end

  test "denies a workspace in the same organization without membership" do
    Current.user = users(:owner)

    assert_raises(Current::WorkspaceAccessDenied) do
      Current.workspace = workspaces(:acme_success)
    end
  end

  test "denies a workspace in another organization" do
    Current.user = users(:owner)

    assert_raises(Current::WorkspaceAccessDenied) do
      Current.workspace = workspaces(:beta_support)
    end
  end

  test "clears the prior workspace after a denied selection" do
    Current.user = users(:owner)
    Current.workspace = workspaces(:acme_support)

    assert_raises(Current::WorkspaceAccessDenied) do
      Current.workspace = workspaces(:beta_support)
    end
    assert_nil Current.workspace
  end

  test "requires an explicit active workspace" do
    assert_raises(Current::WorkspaceAccessDenied) { Current.require_workspace! }
  end

  test "clears the workspace when changing to another member" do
    Membership.create!(user: users(:teammate), workspace: workspaces(:acme_support), role: :member)
    Current.user = users(:owner)
    Current.workspace = workspaces(:acme_support)

    Current.user = users(:teammate)

    assert_nil Current.workspace
  end

  test "revokes an active workspace when membership is removed" do
    Membership.create!(user: users(:teammate), workspace: workspaces(:acme_support), role: :owner)
    Current.user = users(:owner)
    Current.workspace = workspaces(:acme_support)
    memberships(:owner_support).destroy!

    assert_raises(Current::WorkspaceAccessDenied) { Current.require_workspace! }
    assert_nil Current.workspace
  end

  test "checks the current role on every authorization" do
    Current.user = users(:teammate)
    Current.workspace = workspaces(:acme_success)

    assert Current.require_role!(:manager)
    memberships(:teammate_success).update!(role: :viewer)
    assert_raises(Current::RoleAccessDenied) { Current.require_role!(:manager) }
  end
end
