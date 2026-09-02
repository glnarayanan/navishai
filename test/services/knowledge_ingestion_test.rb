require "test_helper"

class KnowledgeIngestionTest < ActiveSupport::TestCase
  class CleanScanner
    def scan(**)
      AttachmentScanner::Result.new(status: :clean, code: "clean")
    end
  end

  setup do
    @workspace = workspaces(:acme_support)
    @membership = memberships(:owner_support)
  end

  test "creates immutable URL versions and searches only the current content with a stable citation" do
    source = KnowledgeIngestion.create!(
      workspace: @workspace, membership: @membership,
      source_kind: :url, title: "Reset access",
      url: "https://DOCS.example.com/reset#steps",
      content: "Use the recovery code from the account owner.",
      expires_at: 2.days.from_now
    )
    original = source.current_version

    assert_equal "https://docs.example.com/reset", source.canonical_url
    assert_equal 1, original.version_number
    assert_equal "knowledge://sources/#{source.source_key}/versions/1", original.citation_uri
    assert_equal @membership.user, original.created_by_user
    assert AuditEvent.where(action: "knowledge.source_created", subject_id: source.id).exists?

    KnowledgeIngestion.update!(
      workspace: @workspace, membership: @membership, knowledge_source: source,
      content: "Use the new recovery link from the account owner.", upload: nil,
      expires_at: 3.days.from_now
    )

    assert_equal 2, source.reload.current_version.version_number
    assert_equal "Use the recovery code from the account owner.", original.reload.content
    assert_empty KnowledgeSearch.search(workspace: @workspace, query: "recovery code")
    result = KnowledgeSearch.search(workspace: @workspace, query: "recovery link").sole
    assert_equal source, result.source
    assert_equal source.current_version, result.version
    assert result.version.association(:knowledge_source).loaded?
    assert_equal source.current_version.citation_uri, result.citation_uri
    assert_equal source, KnowledgeSearch.search(workspace: @workspace, query: "Reset access").sole.source

    assert_raises(KnowledgeIngestion::InvalidSource) do
      KnowledgeIngestion.create!(
        workspace: @workspace, membership: @membership,
        source_kind: :url, title: "Duplicate", url: "https://docs.example.com/reset",
        content: "Duplicate content"
      )
    end
  end

  test "stale and deleted sources preserve warnings and citations but leave current search" do
    source = create_manual(content: "Legacy cancellation steps", expires_at: 1.minute.ago)
    version = source.current_version

    assert source.stale?
    assert KnowledgeSearch.search(workspace: @workspace, query: "cancellation").sole.stale?

    KnowledgeIngestion.new(workspace: @workspace, membership: @membership).delete!(knowledge_source: source)

    assert source.reload.deleted?
    assert_equal version.citation_uri, version.reload.citation_uri
    assert_empty KnowledgeSearch.search(workspace: @workspace, query: "cancellation")
    assert_raises(KnowledgeIngestion::InvalidSource) do
      KnowledgeIngestion.update!(
        workspace: @workspace, membership: @membership, knowledge_source: source,
        content: "Changed after deletion", upload: nil, expires_at: nil
      )
    end
  end

  test "the Intercom Help Center contract appends changed snapshots and suppresses exact retries" do
    first = KnowledgeIngestion.ingest_integration!(
      workspace: @workspace, source_kind: :intercom_help_center,
      title: "Export data", content: "Open Settings and choose Export.", external_id: "article-42",
      source_updated_at: Time.zone.parse("2026-08-20 10:00 UTC"),
      retrieved_at: Time.zone.parse("2026-08-20 11:00 UTC")
    )

    assert_no_difference [ "KnowledgeSource.count", "KnowledgeSourceVersion.count", "AuditEvent.count" ] do
      KnowledgeIngestion.ingest_integration!(
        workspace: @workspace, source_kind: :intercom_help_center,
        title: "Ignored retry title", content: "Open Settings and choose Export.", external_id: "article-42",
        source_updated_at: Time.zone.parse("2026-08-20 10:00 UTC"),
        retrieved_at: Time.zone.parse("2026-08-20 11:05 UTC")
      )
    end

    KnowledgeIngestion.ingest_integration!(
      workspace: @workspace, source_kind: :intercom_help_center,
      title: "Export data", content: "Open Settings, choose Export, then confirm.", external_id: "article-42",
      source_updated_at: Time.zone.parse("2026-08-21 10:00 UTC"),
      retrieved_at: Time.zone.parse("2026-08-21 11:00 UTC")
    )

    assert_equal 2, first.reload.versions.count
    assert_equal 2, first.current_version.version_number
    audit = AuditEvent.find_by!(action: "knowledge.source_created", subject_id: first.id)
    assert audit.system?
    assert audit.source_integration?
  end

  test "a clean text upload is retained while unavailable scanning fails closed without an orphan" do
    previous_scanner = AttachmentScanner.default
    AttachmentScanner.default = CleanScanner.new
    upload = ActionDispatch::Http::UploadedFile.new(
      tempfile: file_fixture("note.txt").open,
      filename: "guide.txt", type: "text/plain"
    )

    source = KnowledgeIngestion.create!(
      workspace: @workspace, membership: @membership,
      source_kind: :upload, title: "Uploaded guide", upload: upload
    )

    assert_equal "Attachment awaiting a malware scan.\n", source.current_version.stored_attachment.download_verified!
    assert source.current_version.stored_attachment.available?
    assert_equal "Attachment awaiting a malware scan.", source.current_version.content
    assert AuditEvent.where(
      action: "attachment.uploaded", subject_type: "StoredAttachment",
      subject_id: source.current_version.stored_attachment_id,
      actor: @membership.user, metadata: { "scan_status" => "available" }
    ).exists?

    AttachmentScanner.default = AttachmentScanner.new
    blobs_before = ActiveStorage::Blob.count
    assert_raises(KnowledgeIngestion::InvalidSource) do
      KnowledgeIngestion.create!(
        workspace: @workspace, membership: @membership,
        source_kind: :upload, title: "Blocked guide",
        upload: ActionDispatch::Http::UploadedFile.new(
          tempfile: file_fixture("note.txt").open,
          filename: "blocked.txt", type: "text/plain"
        )
      )
    end
    assert_equal blobs_before, ActiveStorage::Blob.count
  ensure
    AttachmentScanner.default = previous_scanner
  end

  test "role, tenant, and database boundaries fail closed" do
    viewer = @workspace.memberships.create!(
      user: User.create!(email_address: "knowledge-viewer@example.com", password: "password12345", verified_at: Time.current),
      role: :viewer
    )
    assert_raises(Current::RoleAccessDenied) do
      KnowledgeIngestion.create!(
        workspace: @workspace, membership: viewer,
        source_kind: :manual, title: "Denied", content: "Denied content"
      )
    end

    source = create_manual
    foreign_manager = workspaces(:beta_support).memberships.create!(
      user: User.create!(email_address: "foreign-knowledge-manager@example.com", password: "password12345", verified_at: Time.current),
      role: :manager
    )
    assert_raises(ActiveRecord::RecordNotFound) do
      KnowledgeIngestion.update!(
        workspace: workspaces(:beta_support), membership: foreign_manager,
        knowledge_source: source, content: "Foreign change", upload: nil, expires_at: nil
      )
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      KnowledgeSourceVersion.transaction(requires_new: true) do
        KnowledgeSourceVersion.where(id: source.current_version_id).update_all(content: "Changed")
      end
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      KnowledgeSource.transaction(requires_new: true) do
        KnowledgeSource.where(id: source.id).update_all(title: "Changed")
      end
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      KnowledgeSource.transaction(requires_new: true) do
        KnowledgeSource.create!(
          workspace: @workspace, source_kind: :manual,
          source_key: SecureRandom.uuid, title: "Missing version"
        )
        KnowledgeSource.connection.execute(
          "SET CONSTRAINTS knowledge_sources_require_current_version IMMEDIATE"
        )
      end
    end
  end

  private
    def create_manual(content: "Reset steps for account owners", expires_at: nil)
      KnowledgeIngestion.create!(
        workspace: @workspace, membership: @membership,
        source_kind: :manual, title: "Account access", content:, expires_at:
      )
    end
end
