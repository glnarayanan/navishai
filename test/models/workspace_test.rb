require "test_helper"

class WorkspaceTest < ActiveSupport::TestCase
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
