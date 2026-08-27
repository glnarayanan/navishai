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
    archive = archive_manifest(@compressed)
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
        workspace: source, membership: memberships(:owner_support), archive_io: compressed,
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

  test "round trips historical schema v1 artifacts and published contract families without rewriting history" do
    source = workspaces(:acme_support)
    historical = publish_historical_v1(source)
    archive = WorkspacePortability.export(workspace: source, membership: memberships(:owner_support))

    imported = WorkspacePortability.import(
      workspace: source, membership: memberships(:owner_support), archive_io: archive,
      name: "Historical Restore", slug: "historical-restore"
    )

    restored = imported.crew_artifacts.find_by!(payload_digest: historical.payload_digest)
    assert_equal 1, restored.schema_version
    assert_nil restored.resolution_contract_version
    assert_nil restored.contract_result_state
    assert_empty restored.material_claims
    assert_empty restored.contract_blockers
    assert_equal historical.body, restored.body
    assert_equal ResolutionContractFamily::FAMILIES.keys.sort,
      imported.resolution_contract_families.pluck(:family_key).sort
    assert imported.resolution_contract_families.all? do |family|
      family.current_version && family.current_version.resolution_contract_family_id == family.id
    end
  ensure
    archive&.close!
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
          archive_io: compressed, name: "Wrong Org", slug: "wrong-org"
        )
      end
    end
  end

  test "round trips two incompressible five MiB attachments" do
    source = workspaces(:acme_support)
    contents = 2.times.map { SecureRandom.random_bytes(5.megabytes) }
    contents.each_with_index do |content, index|
      attachment = source.stored_attachments.create!(
        source: :user_upload, uploaded_by_membership: memberships(:owner_support), uploaded_by_user: users(:owner),
        filename: "random-#{index}.bin", byte_size: content.bytesize, content_sha256: Digest::SHA256.hexdigest(content),
        detected_content_type: "application/octet-stream", scan_status: :available, scan_result_code: "clean",
        scanned_at: Time.current
      )
      attachment.file.attach(io: StringIO.new(content), filename: attachment.filename,
        content_type: attachment.detected_content_type)
    end

    archive = WorkspacePortability.export(workspace: source, membership: memberships(:owner_support))
    imported = WorkspacePortability.import(workspace: source, membership: memberships(:owner_support), archive_io: archive,
      name: "Large Restore", slug: "large-restore")

    assert_equal contents.map { |content| Digest::SHA256.hexdigest(content) }.sort,
      imported.stored_attachments.map { |attachment| Digest::SHA256.hexdigest(attachment.download_verified!) }.sort
  ensure
    archive&.close!
  end

  test "rejects a missing attachment object before writing" do
    source = workspaces(:acme_support)
    content = "must exist"
    attachment = source.stored_attachments.create!(
      source: :user_upload, uploaded_by_membership: memberships(:owner_support), uploaded_by_user: users(:owner),
      filename: "required.txt", byte_size: content.bytesize, content_sha256: Digest::SHA256.hexdigest(content),
      detected_content_type: "text/plain", scan_status: :available, scan_result_code: "clean", scanned_at: Time.current
    )
    attachment.file.attach(io: StringIO.new(content), filename: attachment.filename, content_type: "text/plain")
    archive = WorkspacePortability.export(workspace: source, membership: memberships(:owner_support))
    truncated = archive_without_objects(archive)

    assert_no_difference "Workspace.count" do
      assert_raises(WorkspacePortability::InvalidArchive) do
        WorkspacePortability.import(workspace: source, membership: memberships(:owner_support), archive_io: truncated,
          name: "Truncated", slug: "truncated")
      end
    end
  ensure
    archive&.close!
    truncated&.close!
  end

  test "rejects duplicate attachment metadata before writing an object" do
    source = workspaces(:acme_support)
    content = "one object"
    attachment = source.stored_attachments.create!(
      source: :user_upload, uploaded_by_membership: memberships(:owner_support), uploaded_by_user: users(:owner),
      filename: "one.txt", byte_size: content.bytesize, content_sha256: Digest::SHA256.hexdigest(content),
      detected_content_type: "text/plain", scan_status: :available, scan_result_code: "clean", scanned_at: Time.current
    )
    attachment.file.attach(io: StringIO.new(content), filename: attachment.filename, content_type: "text/plain")
    archive = WorkspacePortability.export(workspace: source, membership: memberships(:owner_support))
    duplicate = archive_with_manifest(archive) do |manifest|
      rows = manifest.fetch("tables").fetch("stored_attachments")
      rows << rows.last.dup
    end

    assert_no_difference "Workspace.count" do
      assert_raises(WorkspacePortability::InvalidArchive) do
        WorkspacePortability.import(workspace: source, membership: memberships(:owner_support), archive_io: duplicate,
          name: "Duplicate", slug: "duplicate")
      end
    end
  ensure
    archive&.close!
    duplicate&.close!
  end

  private
    def publish_historical_v1(workspace)
      owner = memberships(:owner_support)
      approve_scripted_runtime(workspace:, membership: owner)
      CrewConfiguration.install_defaults!(workspace:)
      ResolutionContractConfiguration.install_defaults!(workspace:)
      settle_deferred_constraints
      support_case = create_support_case
      settle_deferred_constraints
      profile = workspace.agent_profiles.find_by!(role_key: "support_investigator")
      task = CrewWork.create!(
        workspace:, membership: owner, scope: support_case, profile:, title: "Historical investigation",
        input_context: "Use the current case.", expected_output: "Return schema v1 JSON."
      )
      settle_deferred_constraints
      CrewWork.apply!(
        workspace:, membership: owner, task:, command: :start,
        expected_sequence: task.current_event.sequence_number
      )
      settle_deferred_constraints
      payload = {
        "schema_version" => 1,
        "kind" => "investigation",
        "body" => "The customer reports an expired reset link.",
        "uncertainty" => "The cause is not yet confirmed.",
        "citations" => [ {
          "kind" => "case",
          "locator" => "case://#{support_case.id}",
          "label" => "Support case"
        } ],
        "conflicts" => [],
        "change_requests" => [],
        "review_outcome" => nil,
        "memory_proposals" => []
      }
      run = ExecutionLedger.new(workspace:).prepare!(task:, request_key: "archive:v1:#{task.id}")
      ledger = ExecutionLedger.new(workspace:)
      output = JSON.generate(payload)
      events = [
        [ "run.admitted", { "workspace_key" => workspace.runner_key, "task_key" => task.task_key, "attempt" => 1 } ],
        [ "run.started", { "adapter" => "scripted", "scenario" => "historical v1", "attempt" => 1 } ],
        [ "output.produced", { "text" => output } ],
        [ "run.completed", { "outcome" => "completed" } ]
      ]
      now = Time.current
      events.each_with_index do |(event_type, data), index|
        ledger.ingest!(event: {
          "protocol_version" => "v1", "event_id" => SecureRandom.uuid, "run_id" => run.run_key,
          "sequence" => index + 1, "event_type" => event_type,
          "occurred_at" => (now + (index / 1000.0).seconds).iso8601(6), "data" => data
        })
        settle_deferred_constraints
      end
      run.reload.crew_artifact
    end

    def settle_deferred_constraints
      connection = ActiveRecord::Base.connection
      connection.execute("SET CONSTRAINTS ALL IMMEDIATE")
      connection.execute("SET CONSTRAINTS ALL DEFERRED")
    end

    def archive_manifest(archive)
      archive.rewind
      gzip = Zlib::GzipReader.new(archive)
      manifest = nil
      Gem::Package::TarReader.new(gzip) do |tar|
        manifest = JSON.parse(tar.find { |entry| entry.full_name == "manifest.json" }.read)
      end
      manifest
    end

    def archive_without_objects(archive)
      archive_with_manifest(archive) { |_manifest| }
    end

    def archive_with_manifest(archive)
      output = Tempfile.new([ "truncated", ".tar.gz" ], binmode: true)
      parsed = archive_manifest(archive)
      yield parsed
      manifest = JSON.generate(parsed)
      gzip = Zlib::GzipWriter.new(output)
      begin
        Gem::Package::TarWriter.new(gzip) do |tar|
          tar.add_file_simple("manifest.json", 0o600, manifest.bytesize) { |entry| entry.write(manifest) }
        end
      ensure
        gzip.finish
      end
      output.rewind
      output
    end
end
