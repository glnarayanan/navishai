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

  test "requires an explicit active workspace" do
    assert_raises(Current::WorkspaceAccessDenied) { Current.require_workspace! }
  end

  test "clears the workspace when the user changes" do
    Current.user = users(:owner)
    Current.workspace = workspaces(:acme_support)

    Current.user = users(:outsider)

    assert_nil Current.workspace
  end
end
