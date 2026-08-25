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

  test "imports a complete archive into a new workspace with remapped links and fresh keys" do
    source = workspaces(:acme_support)
    source.shared_email_inboxes.create!(
      name: "Support", email_address: "support@example.com", credential_key: "support"
    )
    content = "verified attachment"
    attachment = source.stored_attachments.create!(
      source: :user_upload, uploaded_by_membership: memberships(:owner_support), uploaded_by_user: users(:owner),
      filename: "proof.txt", byte_size: content.bytesize, content_sha256: Digest::SHA256.hexdigest(content),
      detected_content_type: "text/plain", scan_status: :available, scan_result_code: "clean", scanned_at: Time.current
    )
    attachment.file.attach(io: StringIO.new(content), filename: "proof.txt", content_type: "text/plain")
    source_audit_count = source.audit_events.count
    compressed = WorkspacePortability.export(workspace: source, membership: memberships(:owner_support))

    assert_difference "Workspace.count", 1 do
      @imported = WorkspacePortability.import(
        workspace: source, membership: memberships(:owner_support), archive_io: StringIO.new(compressed),
        name: "Restored Support", slug: "restored-support"
      )
    end

    assert_equal source.organization, @imported.organization
    assert_equal "Restored Support", @imported.name
    assert_not_equal source.runner_key, @imported.runner_key
    assert @imported.memberships.find_by(user: users(:owner)).owner?
    assert_equal source.accounts.count, @imported.accounts.count
    assert_equal source.contacts.count, @imported.contacts.count
    assert_equal source.conversations.count, @imported.conversations.count
    assert_equal source.conversation_messages.count, @imported.conversation_messages.count
    assert_equal source_audit_count, @imported.audit_events.where.not(action: %w[workspace.imported memory.index_reconstructed]).count
    assert_not_equal source.shared_email_inboxes.order(:id).first.webhook_key,
      @imported.shared_email_inboxes.order(:id).first.webhook_key
    assert_equal content, @imported.stored_attachments.sole.download_verified!
    assert_equal @imported.id, @imported.source_identities.find_by!(entity_kind: "account").account.workspace_id
    assert @imported.audit_events.exists?(action: "workspace.imported", actor: users(:owner))
  end

  test "rejects an archive for another organization before writing" do
    source = workspaces(:acme_support)
    compressed = WorkspacePortability.export(workspace: source, membership: memberships(:owner_support))
    organization = Organization.create!(name: "Other Org", slug: "other-org")
    workspace = organization.workspaces.create!(name: "Other Support", slug: "other-support")
    membership = workspace.memberships.create!(user: users(:owner), role: :owner)

    assert_no_difference "Workspace.count" do
      assert_raises(WorkspacePortability::InvalidArchive) do
        WorkspacePortability.import(
          workspace:, membership:,
          archive_io: StringIO.new(compressed), name: "Wrong Org", slug: "wrong-org"
        )
      end
    end
  end
end
