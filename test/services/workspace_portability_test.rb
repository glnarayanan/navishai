require "test_helper"

class WorkspacePortabilityTest < ActiveSupport::TestCase
  test "exports every workspace table without another tenant or user credentials" do
    workspace = workspaces(:acme_support)
    exported_at = Time.zone.parse("2026-08-24 12:00:00")

    assert_difference "AuditEvent.count", 1 do
      @compressed = WorkspacePortability.export(
        workspace:, membership: memberships(:owner_support), exported_at:
      )
    end
    archive = JSON.parse(Zlib::GzipReader.new(StringIO.new(@compressed)).read)
    expected_tables = ActiveRecord::Base.connection.select_values(<<~SQL.squish)
      SELECT table_name FROM information_schema.columns
      WHERE table_schema = 'public' AND column_name = 'workspace_id'
      ORDER BY table_name
    SQL

    assert_equal WorkspacePortability::FORMAT, archive.fetch("format")
    assert_equal exported_at.iso8601(6), archive.fetch("exported_at")
    assert_equal workspace.runner_key, archive.dig("workspace", "runner_key")
    assert_equal expected_tables, archive.fetch("tables").keys
    archive.fetch("tables").each_value do |rows|
      assert rows.all? { |row| row.fetch("workspace_id") == workspace.id }
    end
    user_rows = archive.fetch("users")
    assert_includes user_rows.map { |user| user.fetch("email_address") }, users(:owner).email_address
    refute user_rows.any? { |user| user.key?("password_digest") }
    refute_includes JSON.generate(archive), users(:owner).password_digest
    refute archive.fetch("tables").fetch("accounts").any? { |row| row.fetch("workspace_id") == workspaces(:beta_support).id }

    audit = AuditEvent.order(:id).last
    assert_equal "workspace.exported", audit.action
    assert_equal users(:owner), audit.actor
    assert_equal expected_tables.size, audit.metadata.fetch("table_count")
    assert_operator audit.metadata.fetch("record_count"), :>, 0
  end

  test "only an owner can export a full workspace" do
    workspace = workspaces(:acme_success)

    assert_raises(Current::RoleAccessDenied) do
      WorkspacePortability.export(workspace:, membership: memberships(:teammate_success))
    end
  end
end
