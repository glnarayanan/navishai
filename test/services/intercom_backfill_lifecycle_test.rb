require "test_helper"

class IntercomBackfillLifecycleTest < ActiveSupport::TestCase
  setup do
    @organization = Organization.create!(name: "Backfill lifecycle", slug: "backfill-lifecycle")
    @workspace = @organization.workspaces.create!(name: "Source", slug: "backfill-source")
    @user = User.create!(
      email_address: "backfill-lifecycle@example.com", password: "password12345", verified_at: Time.current
    )
    @owner = @workspace.memberships.create!(user: @user, role: :owner)
    @connection = @workspace.intercom_connections.create!(
      name: "History", remote_workspace_id: "history", credential_key: "history"
    )
    create_backfill_records
  end

  test "retention redacts bounded backfill evidence and leaves its audit attribution" do
    audit = AuditEvent.record!(
      action: "intercom.backfill_completed", source: :job, workspace: @workspace,
      actor_kind: :system, subject: @run, metadata: { conversation_count: 1 }
    )

    expire_workspace_content(@workspace, 1.day.from_now)

    assert_equal [], @manifest.reload.discovery_records
    assert_equal "0" * 64, @manifest.source_digest
    assert_nil @run.reload.last_definite_remote_id
    assert_nil @batch.reload.last_definite_remote_id
    assert_match(/\Aexpired-/, @exception.reload.remote_record_id)
    assert_equal "[Expired by retention policy]", @exception.detail
    assert AuditEvent.exists?(audit.id)
  end

  test "workspace archive round trip remaps every backfill record" do
    ActiveRecord::Base.connection.execute("SET CONSTRAINTS ALL IMMEDIATE")
    archive = WorkspacePortability.export(workspace: @workspace, membership: @owner)

    imported = WorkspacePortability.import(
      workspace: @workspace, membership: @owner, archive_io: archive,
      name: "Restored history", slug: "restored-history"
    )

    restored_run = imported.intercom_backfill_runs.sole
    assert_equal imported.intercom_backfill_manifests.sole, restored_run.intercom_backfill_manifest
    assert_equal imported.intercom_connections.sole, restored_run.intercom_connection
    assert_equal restored_run, imported.intercom_backfill_batches.sole.intercom_backfill_run
    assert_equal restored_run, imported.intercom_backfill_exceptions.sole.intercom_backfill_run
    assert_equal restored_run, imported.intercom_backfill_reports.sole.intercom_backfill_run
    assert_equal @report.report_digest, imported.intercom_backfill_reports.sole.report_digest
  ensure
    archive&.close!
  end

  test "workspace deletion removes all durable backfill state" do
    workspace_id = @workspace.id
    record_ids = [ @manifest.id, @run.id, @batch.id, @exception.id, @report.id ]
    request = WorkspaceDeletion.request!(
      workspace: @workspace, membership: @owner, confirmation: @workspace.slug
    )

    WorkspaceDeletion.perform!(request:, object_purger: ->(*) { })

    refute Workspace.exists?(workspace_id)
    assert_empty IntercomBackfillManifest.where(id: record_ids[0])
    assert_empty IntercomBackfillRun.where(id: record_ids[1])
    assert_empty IntercomBackfillBatch.where(id: record_ids[2])
    assert_empty IntercomBackfillException.where(id: record_ids[3])
    assert_empty IntercomBackfillReport.where(id: record_ids[4])
  end

  private
    def create_backfill_records
      digest = Digest::SHA256.hexdigest("history")
      @manifest = @connection.intercom_backfill_manifests.create!(
        workspace: @workspace, created_by_membership: @owner, created_by_user: @user,
        status: :consumed, source_digest: digest,
        discovery_records: [ { "id" => "conversation-1", "source_digest" => digest } ],
        counts: { "conversations" => 1, "parts" => 0, "notes" => 0, "attachments" => 0 },
        discovered_at: 2.days.ago, expires_at: 1.day.ago, consumed_at: 2.days.ago
      )
      @run = @connection.intercom_backfill_runs.create!(
        workspace: @workspace, intercom_backfill_manifest: @manifest,
        confirmed_by_membership: @owner, confirmed_by_user: @user,
        status: :completed, source_digest: digest, cursor_position: 1,
        counts: report_counts, last_definite_remote_id: "conversation-1",
        last_definite_source_digest: digest, confirmed_at: 2.days.ago, completed_at: 2.days.ago
      )
      @batch = @run.intercom_backfill_batches.create!(
        workspace: @workspace, start_position: 0, end_position: 1, status: :completed,
        source_digest: digest, counts: { "imported" => 1 }, last_definite_remote_id: "conversation-1",
        started_at: 2.days.ago, completed_at: 2.days.ago
      )
      @exception = @manifest.intercom_backfill_exceptions.create!(
        workspace: @workspace, intercom_backfill_run: @run, remote_record_type: "field",
        remote_record_id: "conversation-1:unsupported", source_digest: digest,
        exception_kind: "unsupported_field", status: :resolved, recovery_action: "inspect_source",
        detail: "Unsupported historical field", resolved_at: 2.days.ago
      )
      @report = @run.create_intercom_backfill_report!(
        workspace: @workspace, status: :complete, counts: report_counts,
        report_digest: Digest::SHA256.hexdigest(JSON.generate(report_counts)), generated_at: 2.days.ago
      )
    end

    def report_counts
      {
        "discovered" => 1, "imported" => 1, "matched" => 0, "skipped" => 0,
        "ambiguous" => 0, "unsupported" => 1, "failed" => 0, "pending" => 0,
        "attachments" => 0, "notes" => 0
      }
    end

    def expire_workspace_content(workspace, cutoff)
      connection = ActiveRecord::Base.connection
      connection.select_value(
        "SELECT expire_workspace_content(#{connection.quote(workspace.id)}, #{connection.quote(cutoff)})"
      )
    end
end
