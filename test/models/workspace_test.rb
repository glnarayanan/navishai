require "test_helper"

class WorkspaceTest < ActiveSupport::TestCase
  test "runner key is unique and cannot change after creation" do
    workspace = workspaces(:acme_support)

    assert_match RunnerProtocol::UUID_PATTERN, workspace.runner_key
    duplicate = workspaces(:acme_success)
    duplicate.runner_key = workspace.runner_key
    assert_not duplicate.valid?
    assert_raises(ActiveRecord::StatementInvalid) do
      Workspace.transaction(requires_new: true) { Workspace.where(id: workspace.id).update_all(runner_key: SecureRandom.uuid) }
    end
  end

  test "allows the same slug in different organizations" do
    assert_equal "support", workspaces(:acme_support).slug
    assert_equal "support", workspaces(:beta_support).slug
  end

  test "requires a unique slug within an organization" do
    workspace = Workspace.new(organization: organizations(:acme), name: "Other", slug: "support")

    assert_not workspace.valid?
    assert_includes workspace.errors[:slug], "has already been taken"
  end

  test "accessible_to returns only joined workspaces" do
    assert_equal [ workspaces(:acme_support) ], Workspace.accessible_to(users(:owner)).to_a
  end
end
