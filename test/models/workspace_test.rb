require "test_helper"

class WorkspaceTest < ActiveSupport::TestCase
  test "workspace has no old domain configuration or runner key" do
    workspace = workspaces(:acme_support)
    assert_not workspace.has_attribute?(:runner_key)
    assert_empty Workspace.reflect_on_all_associations.map(&:name) & %i[support_cases accounts crew_tasks memory_records interventions]
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
