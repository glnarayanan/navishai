require "test_helper"

class WorkspaceDataPolicyTest < ActiveSupport::TestCase
  test "derives independent content and audit cutoffs" do
    policy = WorkspaceDataPolicy.new(content_retention_days: 90, audit_retention_days: 365)
    now = Time.zone.parse("2026-08-24 12:00:00")

    assert_equal now - 90.days, policy.content_cutoff(at: now)
    assert_equal now - 365.days, policy.audit_cutoff(at: now)
  end

  test "new workspaces get an indefinite policy" do
    workspace = organizations(:acme).workspaces.create!(name: "Retention test", slug: "retention-test")

    assert_nil workspace.workspace_data_policy.content_retention_days
    assert_nil workspace.workspace_data_policy.audit_retention_days
  end
end
