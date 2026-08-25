require "test_helper"

class AttachmentIntakeTest < ActiveSupport::TestCase
  class CleanScanner
    def scan(**)
      AttachmentScanner::Result.new(status: :clean, code: "clean")
    end
  end

  test "sniffs content bytes and stores a clean file behind a workspace record" do
    prepared = AttachmentIntake.prepare!(
      [ { filename: "report.exe", data: "%PDF-1.7\nreport" } ],
      scanner: CleanScanner.new
    )

    attachment = AttachmentIntake.persist!(
      workspace: workspaces(:acme_support), prepared: prepared,
      source: :inbound_email
    ).sole

    assert attachment.available?
    assert_equal "application/pdf", attachment.detected_content_type
    assert_equal "%PDF-1.7\nreport", attachment.file.download
  end

  test "unknown binary content is retained but blocked" do
    prepared = AttachmentIntake.prepare!(
      [ { filename: "payload.txt", data: "MZ\x00\x01payload".b } ],
      scanner: CleanScanner.new
    )

    attachment = AttachmentIntake.persist!(
      workspace: workspaces(:acme_support), prepared: prepared,
      source: :inbound_email
    ).sole

    assert attachment.rejected?
    assert_equal "unsupported_type", attachment.scan_result_code
    assert_equal "application/octet-stream", attachment.detected_content_type
  end

  test "scanner outages quarantine content and size limits create no blob" do
    prepared = AttachmentIntake.prepare!([ { filename: "note.txt", data: "safe text" } ])
    attachment = AttachmentIntake.persist!(
      workspace: workspaces(:acme_support), prepared: prepared,
      source: :inbound_email
    ).sole

    assert attachment.quarantined?
    assert_equal "scanner_unavailable", attachment.scan_result_code

    assert_no_difference "ActiveStorage::Blob.count" do
      assert_raises(AttachmentIntake::InvalidAttachment) do
        AttachmentIntake.prepare!([ { filename: "large.txt", data: "a" * (StoredAttachment::MAX_BYTES + 1) } ])
      end
    end
  end

  test "scanner errors fail closed and unsafe filenames are reduced to a basename" do
    scanner = Class.new do
      def scan(**)
        raise IOError, "scanner offline"
      end
    end.new

    prepared = AttachmentIntake.prepare!([
      { filename: "../../private\u0000note.txt", data: "safe text" }
    ], scanner: scanner)
    attachment = AttachmentIntake.persist!(
      workspace: workspaces(:acme_support), prepared: prepared, source: :inbound_email
    ).sole

    assert attachment.quarantined?
    assert_equal "scanner_unavailable", attachment.scan_result_code
    assert_equal "privatenote.txt", attachment.filename
  end

  test "count and total-size failures clean up every prepared blob" do
    assert_no_difference "ActiveStorage::Blob.count" do
      assert_raises(AttachmentIntake::InvalidAttachment) do
        AttachmentIntake.prepare!(
          6.times.map { |index| { filename: "#{index}.txt", data: "file" } },
          scanner: CleanScanner.new
        )
      end
    end

    assert_no_difference "ActiveStorage::Blob.count" do
      assert_raises(AttachmentIntake::InvalidAttachment) do
        AttachmentIntake.prepare!(
          3.times.map { |index| { filename: "#{index}.txt", data: "a" * 4.megabytes } },
          scanner: CleanScanner.new
        )
      end
    end
  end

  test "preparation cleans up every uploaded object when a later file is invalid" do
    keys_before = ActiveStorage::Blob.pluck(:key)

    assert_raises(AttachmentIntake::InvalidAttachment) do
      AttachmentIntake.prepare!([
        { filename: "valid.txt", data: "uploaded first" },
        { filename: "empty.txt", data: "" }
      ], scanner: CleanScanner.new)
    end

    assert_equal keys_before, ActiveStorage::Blob.pluck(:key)
  end

  test "stored records and file links are durable after the scan decision" do
    attachment = AttachmentIntake.persist!(
      workspace: workspaces(:acme_support),
      prepared: AttachmentIntake.prepare!([
        { filename: "durable.txt", data: "durable bytes" }
      ], scanner: CleanScanner.new),
      source: :inbound_email
    ).sole

    assert_raises(ActiveRecord::StatementInvalid) do
      StoredAttachment.transaction(requires_new: true) do
        StoredAttachment.where(id: attachment.id).update_all(id: attachment.id + 1_000_000)
      end
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      ActiveStorage::Blob.transaction(requires_new: true) do
        ActiveStorage::Blob.where(id: attachment.file.blob_id).update_all(content_type: "text/html")
      end
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      ActiveStorage::Attachment.transaction(requires_new: true) do
        file = attachment.file_attachment
        ActiveStorage::Attachment.where(id: file.id).update_all(id: file.id + 1_000_000)
      end
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      ActiveStorage::Attachment.transaction(requires_new: true) do
        ActiveStorage::Attachment.where(id: attachment.file_attachment.id).delete_all
      end
    end
    assert_equal "durable.txt", attachment.reload.filename
    assert attachment.file.attached?
  end

  test "the database rejects quarantined and foreign files on outbound messages" do
    workspace = workspaces(:acme_support)
    support_case = create_support_case(
      workspace: workspace, contact: contacts(:alice), membership: memberships(:owner_support)
    )
    message = ConversationThread.append_outbound!(
      workspace: workspace, conversation: support_case.conversation,
      membership: memberships(:owner_support), body: "Staff reply",
      occurred_at: Time.current, source: :web
    )
    quarantined = AttachmentIntake.persist!(
      workspace: workspace,
      prepared: AttachmentIntake.prepare!([ { filename: "pending.txt", data: "pending" } ]),
      source: :inbound_email
    ).sole
    foreign = AttachmentIntake.persist!(
      workspace: workspaces(:beta_support),
      prepared: AttachmentIntake.prepare!([
        { filename: "foreign.txt", data: "foreign" }
      ], scanner: CleanScanner.new),
      source: :inbound_email
    ).sole

    assert_raises(ActiveRecord::StatementInvalid) do
      ConversationMessageAttachment.transaction(requires_new: true) do
        ConversationMessageAttachment.create!(
          workspace: workspace, conversation: support_case.conversation,
          conversation_message: message, stored_attachment: quarantined
        )
      end
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      ConversationMessageAttachment.transaction(requires_new: true) do
        ConversationMessageAttachment.insert_all!([ {
          workspace_id: workspace.id,
          conversation_id: support_case.conversation_id,
          conversation_message_id: message.id,
          stored_attachment_id: foreign.id,
          created_at: Time.current,
          updated_at: Time.current
        } ])
      end
    end
    assert_empty message.reload.stored_attachments
  end
end
