require "test_helper"

class EmailAttachmentWorkflowTest < ActiveSupport::TestCase
  class CleanScanner
    def scan(**)
      AttachmentScanner::Result.new(status: :clean, code: "clean")
    end
  end

  setup do
    @workspace = workspaces(:acme_support)
    @membership = memberships(:owner_support)
    inbox = @workspace.shared_email_inboxes.create!(
      name: "Support", email_address: "support@example.com", credential_key: "support"
    )
    intake = SharedEmailIntake.receive!(
      inbox: inbox, raw_email: raw_email,
      received_at: Time.zone.parse("2026-08-24 12:00:00 UTC")
    )
    @support_case = intake.conversation.support_case
    @draft = EmailDraftWorkflow.save!(
      workspace: @workspace, support_case: @support_case,
      membership: @membership, body: "Draft reply", expected_lock_version: "new"
    )
  end

  test "adds and removes a scanned attachment with fresh role and draft checks" do
    assert_difference [ "StoredAttachment.count", "EmailDraftAttachment.count" ], 1 do
      @attachment = EmailAttachmentWorkflow.add!(
        workspace: @workspace, support_case: @support_case, membership: @membership,
        draft_version: @draft.lock_version,
        files: [ { filename: "answer.txt", data: "safe answer" } ], scanner: CleanScanner.new
      ).sole
    end

    assert @attachment.available?
    assert_equal users(:owner), @attachment.uploaded_by_user
    assert AuditEvent.where(action: "attachment.uploaded", subject_id: @attachment.id).exists?

    assert_difference "EmailDraftAttachment.count", -1 do
      EmailAttachmentWorkflow.remove!(
        workspace: @workspace, support_case: @support_case, membership: @membership,
        attachment: @attachment, draft_version: @draft.reload.lock_version
      )
    end
    assert StoredAttachment.exists?(@attachment.id)
  end

  test "viewer and stale draft attempts leave no attachment or blob" do
    viewer = @workspace.memberships.create!(
      user: User.create!(email_address: "attachment-viewer@example.com", password: "password12345", verified_at: Time.current),
      role: :viewer
    )

    assert_no_difference [ "StoredAttachment.count", "ActiveStorage::Blob.count", "AuditEvent.count" ] do
      assert_raises(Current::RoleAccessDenied) do
        EmailAttachmentWorkflow.add!(
          workspace: @workspace, support_case: @support_case, membership: viewer,
          draft_version: @draft.lock_version,
          files: [ { filename: "forged.txt", data: "forged" } ], scanner: CleanScanner.new
        )
      end
    end

    assert_no_difference [ "StoredAttachment.count", "ActiveStorage::Blob.count" ] do
      assert_raises(ActiveRecord::StaleObjectError) do
        EmailAttachmentWorkflow.add!(
          workspace: @workspace, support_case: @support_case, membership: @membership,
          draft_version: -1,
          files: [ { filename: "stale.txt", data: "stale" } ], scanner: CleanScanner.new
        )
      end
    end
  end

  private
    def raw_email
      <<~EMAIL.gsub("\n", "\r\n")
        From: Alice Example <alice@example.net>
        To: Support <support@example.com>
        Date: Mon, 24 Aug 2026 11:55:00 +0000
        Subject: Email help
        Message-ID: <attachment-root@example.net>
        MIME-Version: 1.0
        Content-Type: text/plain; charset=UTF-8

        Please help
      EMAIL
    end
end
