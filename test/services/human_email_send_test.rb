require "test_helper"

class HumanEmailSendTest < ActiveSupport::TestCase
  class CleanScanner
    def scan(**)
      AttachmentScanner::Result.new(status: :clean, code: "clean")
    end
  end

  class RecordingTransport
    attr_reader :deliveries

    def initialize(error: nil)
      @error = error
      @deliveries = []
    end

    def deliver!(**attributes)
      @deliveries << attributes
      raise @error if @error

      true
    end
  end

  setup do
    @workspace = workspaces(:acme_support)
    @membership = memberships(:owner_support)
    Current.session = users(:owner).sessions.create!(authentication_method: :local, expires_at: 12.hours.from_now)
    @inbox = @workspace.shared_email_inboxes.create!(
      name: "Support",
      email_address: "support@example.com",
      credential_key: "support"
    )
    delivery = SharedEmailIntake.receive!(
      inbox: @inbox,
      raw_email: raw_email,
      received_at: Time.zone.parse("2026-08-24 12:00:00 UTC")
    )
    @support_case = delivery.conversation.support_case
    @thread = delivery.conversation.email_threads.sole
  end

  test "sends the frozen plain-text message once and records the human result" do
    transport = RecordingTransport.new

    assert_difference [ "OutboundEmailDelivery.count", "ConversationMessage.outbound.count" ], 1 do
      @delivery = send_email(transport: transport)
    end

    assert @delivery.sent?
    assert @delivery.email_draft.reload.sent?
    assert_equal users(:owner), @delivery.actor_user
    assert_equal @membership, @delivery.actor_membership
    assert_equal "alice@example.net", @delivery.to_address
    assert_equal "Re: Email help", @delivery.subject
    assert_equal "A human reply", @delivery.conversation_message.body
    assert_equal [ "root@example.net" ], transport.deliveries.sole[:references]
    assert_equal @delivery.message_id, transport.deliveries.sole[:message_id]
    assert AuditEvent.where(
      action: "email.send_succeeded", subject_type: "OutboundEmailDelivery",
      subject_id: @delivery.id, actor: users(:owner)
    ).exists?
  end

  test "uses the newest trusted inbound reply target and parent despite delayed processing" do
    SharedEmailIntake.receive!(
      inbox: @inbox,
      raw_email: raw_email(
        message_id: "newest@example.net", references: "root@example.net",
        reply_to: "alice+current@example.org", body: "Newest reply"
      ),
      received_at: Time.zone.parse("2026-08-24 12:10:00 UTC")
    )
    SharedEmailIntake.receive!(
      inbox: @inbox,
      raw_email: raw_email(
        message_id: "delayed@example.net", references: "root@example.net",
        reply_to: "alice+old@example.org", body: "Delayed reply"
      ),
      received_at: Time.zone.parse("2026-08-24 12:05:00 UTC")
    )
    transport = RecordingTransport.new

    preview = HumanEmailSend.recipient_preview(workspace: @workspace, support_case: @support_case)
    assert_equal "alice+current@example.org", preview.address
    refute preview.trusted
    assert_no_difference "OutboundEmailDelivery.count" do
      assert_raises(ArgumentError) { send_email(transport: transport) }
    end
    assert_no_difference "OutboundEmailDelivery.count" do
      assert_raises(ArgumentError) do
        send_email(transport: transport, confirmed_recipient_address: "alice+old@example.org")
      end
    end
    assert_no_difference "OutboundEmailDelivery.count" do
      assert_raises(ArgumentError) do
        send_email(
          transport: transport,
          expected_recipient_address: "alice+old@example.org",
          expected_inbound_message_id: preview.inbound_message_id,
          confirmed_recipient_address: "alice+current@example.org"
        )
      end
    end
    delivery = send_email(transport: transport, confirmed_recipient_address: "alice+current@example.org")

    assert_equal "alice+current@example.org", delivery.to_address
    assert_equal "newest@example.net", delivery.in_reply_to_message_id
    assert_equal "alice+current@example.org", transport.deliveries.sole[:to]
    assert_equal "newest@example.net", transport.deliveries.sole[:in_reply_to]
  end

  test "a new inbound after preview blocks a stale send even when the recipient is unchanged" do
    preview = HumanEmailSend.recipient_preview(workspace: @workspace, support_case: @support_case)
    SharedEmailIntake.receive!(
      inbox: @inbox,
      raw_email: raw_email(message_id: "after-preview@example.net", references: "root@example.net"),
      received_at: Time.zone.parse("2026-08-24 12:10:00 UTC")
    )
    transport = RecordingTransport.new

    assert_no_difference [ "OutboundEmailDelivery.count", "ConversationMessage.outbound.count" ] do
      error = assert_raises(ArgumentError) do
        send_email(
          expected_recipient_address: preview.address,
          expected_inbound_message_id: preview.inbound_message_id,
          transport: transport
        )
      end
      assert_match(/new customer message/i, error.message)
    end
    assert_empty transport.deliveries
  end

  test "a fresh inbound after a sent reply permits a second fresh human send" do
    first = send_email
    SharedEmailIntake.receive!(
      inbox: @inbox,
      raw_email: raw_email(
        message_id: "follow-up@example.net", references: first.message_id,
        body: "Customer follow-up"
      ),
      received_at: first.sent_at + 5.minutes
    )
    transport = RecordingTransport.new

    second = send_email(
      key: "second-send", body: "Second human reply",
      draft_version: first.email_draft.reload.lock_version.to_s,
      transport: transport
    )

    assert second.sent?
    assert_not_equal first.id, second.id
    assert_equal "follow-up@example.net", second.in_reply_to_message_id
    assert_equal "Second human reply", second.conversation_message.body
    assert_equal 2, @support_case.conversation.conversation_messages.outbound.count
  end

  test "claim freezes artifact and edit provenance before the reusable draft becomes a follow-up" do
    artifact = create_draft_artifact(
      workspace: @workspace, support_case: @support_case, membership: @membership,
      body: "Generated email answer", result_state: "needs_human"
    )
    draft = EmailDraftWorkflow.save!(
      workspace: @workspace, support_case: @support_case, membership: @membership,
      body: artifact.body, expected_lock_version: "new",
      source_crew_artifact_id: artifact.id, adopt_source: true
    )

    delivery = send_email(
      key: "artifact-send", body: "Human-qualified final email",
      draft_version: draft.lock_version.to_s, source_crew_artifact_id: artifact.id
    )

    assert_equal artifact, delivery.source_crew_artifact
    assert_equal Digest::SHA256.hexdigest(artifact.body), delivery.generated_body_digest
    assert_equal "needs_human", delivery.generated_contract_result_state
    assert_equal @membership, delivery.human_edited_by_membership
    assert_equal @membership.user, delivery.human_edited_by_user
    assert delivery.human_edited_at
    assert_equal "Human-qualified final email", delivery.body
    assert_equal @membership.user, delivery.actor_user

    SharedEmailIntake.receive!(
      inbox: @inbox,
      raw_email: raw_email(
        message_id: "provenance-follow-up@example.net", references: delivery.message_id,
        body: "Customer follow-up"
      ),
      received_at: delivery.sent_at + 5.minutes
    )
    EmailDraftWorkflow.save!(
      workspace: @workspace, support_case: @support_case, membership: @membership,
      body: "New human-authored follow-up", expected_lock_version: draft.reload.lock_version.to_s
    )

    assert_nil draft.reload.source_crew_artifact
    assert_nil draft.generated_body_digest
    assert_equal artifact, delivery.reload.source_crew_artifact
    assert_equal "needs_human", delivery.generated_contract_result_state
    assert_equal "Human-qualified final email", delivery.body
    assert_raises(ActiveRecord::StatementInvalid) do
      OutboundEmailDelivery.transaction(requires_new: true) do
        OutboundEmailDelivery.where(id: delivery.id).update_all(source_crew_artifact_id: nil)
      end
    end
  end

  test "sends only scanned draft attachments and links the frozen file to the outbound message" do
    draft = EmailDraftWorkflow.save!(
      workspace: @workspace, support_case: @support_case, membership: @membership,
      body: "A human reply", expected_lock_version: "new"
    )
    attachment = EmailAttachmentWorkflow.add!(
      workspace: @workspace, support_case: @support_case, membership: @membership,
      draft_version: draft.lock_version,
      files: [ { filename: "details.txt", data: "frozen details" } ], scanner: CleanScanner.new
    ).sole
    transport = RecordingTransport.new

    delivery = send_email(
      draft_version: draft.reload.lock_version.to_s,
      transport: transport
    )

    assert delivery.sent?
    assert_equal [ attachment ], delivery.stored_attachments
    assert_equal [ attachment ], delivery.conversation_message.stored_attachments
    sent_attachment = transport.deliveries.sole[:attachments].sole
    assert_equal "details.txt", sent_attachment[:filename]
    assert_equal "frozen details", sent_attachment[:content]

    SharedEmailIntake.receive!(
      inbox: @inbox,
      raw_email: raw_email(
        message_id: "attachment-follow-up@example.net", references: delivery.message_id,
        body: "Follow-up without the old file"
      ),
      received_at: delivery.sent_at + 5.minutes
    )
    EmailDraftWorkflow.save!(
      workspace: @workspace, support_case: @support_case, membership: @membership,
      body: "New reply", expected_lock_version: draft.reload.lock_version.to_s
    )
    assert_empty draft.reload.stored_attachments
    assert_equal [ attachment ], delivery.reload.stored_attachments
    assert_equal [ attachment ], delivery.conversation_message.stored_attachments
  end

  test "quarantined draft attachments block SMTP and roll back the send claim" do
    draft = EmailDraftWorkflow.save!(
      workspace: @workspace, support_case: @support_case, membership: @membership,
      body: "A human reply", expected_lock_version: "new"
    )
    EmailAttachmentWorkflow.add!(
      workspace: @workspace, support_case: @support_case, membership: @membership,
      draft_version: draft.lock_version,
      files: [ { filename: "pending.txt", data: "pending scan" } ]
    )
    transport = RecordingTransport.new

    assert_no_difference [ "OutboundEmailDelivery.count", "ConversationMessage.outbound.count" ] do
      assert_raises(AttachmentIntake::InvalidAttachment) do
        send_email(draft_version: draft.reload.lock_version.to_s, transport: transport)
      end
    end
    assert_empty transport.deliveries
    assert draft.reload.ready?
  end

  test "a changed attachment object fails before SMTP and permits a fresh retry" do
    draft = EmailDraftWorkflow.save!(
      workspace: @workspace, support_case: @support_case, membership: @membership,
      body: "A human reply", expected_lock_version: "new"
    )
    attachment = EmailAttachmentWorkflow.add!(
      workspace: @workspace, support_case: @support_case, membership: @membership,
      draft_version: draft.lock_version,
      files: [ { filename: "changed.txt", data: "scanned bytes" } ], scanner: CleanScanner.new
    ).sole
    attachment.file.blob.service.upload(attachment.file.key, StringIO.new("changed bytes"))
    transport = RecordingTransport.new

    delivery = send_email(draft_version: draft.reload.lock_version.to_s, transport: transport)

    assert delivery.failed?
    assert_equal "attachment_unavailable", delivery.failure_code
    assert delivery.email_draft.reload.ready?
    assert_empty transport.deliveries
    assert_nil delivery.conversation_message
  end

  test "an idempotent replay cannot send twice or cross cases" do
    transport = RecordingTransport.new
    first = send_email(transport: transport)

    assert_no_difference [ "OutboundEmailDelivery.count", "ConversationMessage.count" ] do
      assert_equal first, send_email(transport: transport)
    end
    assert_equal 1, transport.deliveries.size

    other_delivery = SharedEmailIntake.receive!(
      inbox: @inbox,
      raw_email: raw_email(message_id: "other@example.net"),
      received_at: Time.zone.parse("2026-08-24 12:05:00 UTC")
    )
    assert_raises(ActiveRecord::RecordNotFound) do
      send_email(support_case: other_delivery.conversation.support_case, transport: transport)
    end
  end

  test "a replay while the first delivery is in progress cannot send twice" do
    transport = RecordingTransport.new
    delivery = @workspace.outbound_email_deliveries.create!(
      email_draft: EmailDraftWorkflow.save!(
        workspace: @workspace, support_case: @support_case, membership: @membership,
        body: "A human reply", expected_lock_version: "new"
      ),
      shared_email_inbox: @inbox, email_thread: @thread,
      conversation: @support_case.conversation,
      actor_membership: @membership, actor_user: @membership.user,
      idempotency_key: "send-key", message_id: "in-progress@navishai.local",
      in_reply_to_message_id: "root@example.net", from_address: @inbox.email_address,
      to_address: "alice@example.net", subject: "Re: Email help", body: "A human reply",
      started_at: Time.current
    )
    delivery.email_draft.update!(status: :sending)

    assert_no_difference [ "OutboundEmailDelivery.count", "ConversationMessage.outbound.count" ] do
      assert_equal delivery, send_email(transport: transport)
    end
    assert_empty transport.deliveries
  end

  test "a missing contemporaneous browser session cannot be supplied by a job or agent" do
    Current.session = nil

    assert_no_difference [ "OutboundEmailDelivery.count", "ConversationMessage.count", "AuditEvent.count" ] do
      assert_raises(ActiveRecord::RecordNotFound) { send_email }
    end
  end

  test "a stale viewer role blocks the send before SMTP" do
    @membership.update_column(:role, "viewer")
    transport = RecordingTransport.new

    assert_no_difference [ "OutboundEmailDelivery.count", "ConversationMessage.count", "AuditEvent.count" ] do
      assert_raises(Current::RoleAccessDenied) { send_email(transport: transport) }
    end
    assert_empty transport.deliveries
  end

  test "a session revoked after claim blocks SMTP" do
    transport = RecordingTransport.new
    original = HumanSendAuthorization.method(:with_current_authority)
    authorization = HumanSendAuthorization.singleton_class
    revoke_before_lock = lambda do |**arguments, &block|
      Current.session.revoke!
      original.call(**arguments, &block)
    end
    authorization.define_method(:with_current_authority, revoke_before_lock)

    assert_raises(ActiveRecord::RecordNotFound) do
      send_email(transport: transport)
    end

    assert_empty transport.deliveries
    delivery = @workspace.outbound_email_deliveries.sole
    assert delivery.failed?
    assert_equal "authorization_changed", delivery.failure_code
    assert delivery.email_draft.reload.ready?
  ensure
    authorization&.define_method(:with_current_authority, original)
  end

  test "a definite configuration failure allows a fresh human retry" do
    transport = RecordingTransport.new(error: SharedEmailSmtpTransport::ConfigurationError.new("not configured"))

    delivery = send_email(transport: transport)

    assert delivery.failed?
    assert_equal "configuration_error", delivery.failure_code
    assert delivery.email_draft.reload.ready?
    assert_nil delivery.conversation_message
  end

  test "an ambiguous SMTP outcome blocks every automatic or fresh retry" do
    transport = RecordingTransport.new(error: Net::ReadTimeout.new("timeout"))
    delivery = send_email(transport: transport)

    assert delivery.unknown?
    assert delivery.email_draft.reload.sending?
    assert_no_difference [ "OutboundEmailDelivery.count", "ConversationMessage.count" ] do
      assert_equal delivery, send_email(transport: RecordingTransport.new)
    end
    assert_raises(ArgumentError) do
      send_email(key: "fresh-key", draft_version: delivery.email_draft.lock_version.to_s, transport: RecordingTransport.new)
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      OutboundEmailDelivery.transaction(requires_new: true) do
        OutboundEmailDelivery.where(id: delivery.id).update_all(
          id: delivery.id + 1_000_000, status: "failed", failure_code: "confirmed_not_sent"
        )
      end
    end
  end

  test "a fresh human can confirm an ambiguous delivery was accepted" do
    draft = EmailDraftWorkflow.save!(
      workspace: @workspace, support_case: @support_case, membership: @membership,
      body: "A human reply", expected_lock_version: "new"
    )
    attachment = EmailAttachmentWorkflow.add!(
      workspace: @workspace, support_case: @support_case, membership: @membership,
      draft_version: draft.lock_version,
      files: [ { filename: "confirmed.txt", data: "confirmed bytes" } ], scanner: CleanScanner.new
    ).sole
    delivery = send_email(
      draft_version: draft.reload.lock_version.to_s,
      transport: RecordingTransport.new(error: Net::ReadTimeout.new("timeout"))
    )
    reviewer = User.create!(email_address: "delivery-reviewer@example.com", password: "password12345", verified_at: Time.current)
    reviewer_membership = @workspace.memberships.create!(user: reviewer, role: :owner)
    @membership.update!(role: :viewer)
    Current.session = reviewer.sessions.create!(authentication_method: :local, expires_at: 12.hours.from_now)

    assert_difference "ConversationMessage.outbound.count", 1 do
      HumanEmailSend.review_unknown!(
        workspace: @workspace, support_case: @support_case,
        membership: reviewer_membership, delivery: delivery, outcome: "accepted"
      )
    end

    assert delivery.reload.sent?
    assert_equal delivery.started_at, delivery.sent_at
    assert_equal users(:owner), delivery.conversation_message.author_user
    assert_equal [ attachment ], delivery.conversation_message.stored_attachments
    assert delivery.email_draft.reload.sent?
    assert AuditEvent.where(action: "email.send_reviewed", actor: reviewer, subject_id: delivery.id, metadata: { outcome: "accepted" }).exists?
  end

  test "a fresh human can confirm an ambiguous delivery was rejected and retry" do
    delivery = send_email(transport: RecordingTransport.new(error: Net::ReadTimeout.new("timeout")))

    HumanEmailSend.review_unknown!(
      workspace: @workspace, support_case: @support_case,
      membership: @membership, delivery: delivery, outcome: "rejected"
    )

    assert delivery.reload.failed?
    assert_equal "confirmed_not_sent", delivery.failure_code
    assert delivery.email_draft.reload.ready?
    retry_transport = RecordingTransport.new
    retried = send_email(
      key: "reviewed-retry", draft_version: delivery.email_draft.lock_version.to_s,
      transport: retry_transport
    )
    assert retried.sent?
    assert_equal 1, retry_transport.deliveries.size
  end

  test "a crashed sending claim can be reviewed but a live advisory lock cannot" do
    draft = EmailDraftWorkflow.save!(
      workspace: @workspace, support_case: @support_case, membership: @membership,
      body: "A human reply", expected_lock_version: "new"
    )
    delivery = @workspace.outbound_email_deliveries.create!(
      email_draft: draft, shared_email_inbox: @inbox, email_thread: @thread,
      conversation: @support_case.conversation,
      actor_membership: @membership, actor_user: @membership.user,
      idempotency_key: "crashed-send", message_id: "crashed@navishai.local",
      in_reply_to_message_id: "root@example.net", from_address: @inbox.email_address,
      to_address: "alice@example.net", subject: "Re: Email help", body: draft.body,
      started_at: 1.hour.ago
    )
    draft.update!(status: :sending)
    database = ActiveRecord::Base.connection.select_value("SELECT current_database()")
    lock_connection = PG.connect(dbname: database)
    lock_connection.exec(
      "SELECT pg_advisory_lock(#{HumanEmailSend::DELIVERY_LOCK_NAMESPACE}, #{delivery.id})"
    )

    assert_raises(ArgumentError) do
      HumanEmailSend.review_unknown!(
        workspace: @workspace, support_case: @support_case,
        membership: @membership, delivery: delivery, outcome: "rejected"
      )
    end
    assert delivery.reload.sending?

    lock_connection.exec(
      "SELECT pg_advisory_unlock(#{HumanEmailSend::DELIVERY_LOCK_NAMESPACE}, #{delivery.id})"
    )
    lock_connection.close
    lock_connection = nil
    HumanEmailSend.review_unknown!(
      workspace: @workspace, support_case: @support_case,
      membership: @membership, delivery: delivery, outcome: "rejected"
    )
    assert delivery.reload.failed?
    assert_equal "confirmed_not_sent", delivery.failure_code
  ensure
    lock_connection&.close
  end

  test "an opposite stale review conflicts while a same-outcome replay is idempotent" do
    delivery = send_email(transport: RecordingTransport.new(error: Net::ReadTimeout.new("timeout")))
    HumanEmailSend.review_unknown!(
      workspace: @workspace, support_case: @support_case,
      membership: @membership, delivery: delivery, outcome: "accepted"
    )

    assert_equal delivery, HumanEmailSend.review_unknown!(
      workspace: @workspace, support_case: @support_case,
      membership: @membership, delivery: delivery, outcome: "accepted"
    )
    assert_raises(ArgumentError) do
      HumanEmailSend.review_unknown!(
        workspace: @workspace, support_case: @support_case,
        membership: @membership, delivery: delivery, outcome: "rejected"
      )
    end
    assert delivery.reload.sent?
  end

  test "a persistence failure after SMTP acceptance becomes review required" do
    transport = RecordingTransport.new
    connection = ConversationMessage.connection
    connection.execute <<~SQL
      CREATE FUNCTION reject_test_outbound_message() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN RAISE EXCEPTION 'write failed'; END;
      $$;
      CREATE TRIGGER reject_test_outbound_message
      BEFORE INSERT ON conversation_messages FOR EACH ROW
      WHEN (NEW.direction = 'outbound') EXECUTE FUNCTION reject_test_outbound_message();
    SQL

    assert_raises(ActiveRecord::StatementInvalid) { send_email(transport: transport) }

    delivery = @workspace.outbound_email_deliveries.sole
    assert_equal 1, transport.deliveries.size
    assert delivery.reload.unknown?
    assert delivery.email_draft.reload.sending?
    assert_nil delivery.conversation_message
  ensure
    connection&.execute("DROP TRIGGER IF EXISTS reject_test_outbound_message ON conversation_messages")
    connection&.execute("DROP FUNCTION IF EXISTS reject_test_outbound_message()")
  end

  test "the database freezes delivery content and terminal records" do
    delivery = send_email

    assert_raises(ActiveRecord::StatementInvalid) do
      OutboundEmailDelivery.transaction(requires_new: true) do
        OutboundEmailDelivery.where(id: delivery.id).update_all(body: "Changed")
      end
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      OutboundEmailDelivery.transaction(requires_new: true) do
        OutboundEmailDelivery.where(id: delivery.id).delete_all
      end
    end
    assert_equal "A human reply", delivery.reload.body
  end

  private
    def send_email(support_case: @support_case, key: "send-key", body: "A human reply", draft_version: "new",
      source_crew_artifact_id: nil, expected_recipient_address: nil, expected_inbound_message_id: nil,
      confirmed_recipient_address: nil, transport: RecordingTransport.new)
      preview = HumanEmailSend.recipient_preview(workspace: @workspace, support_case: support_case)
      HumanEmailSend.send!(
        workspace: @workspace,
        support_case: support_case,
        membership: @membership,
        body: body,
        draft_version: draft_version,
        idempotency_key: key,
        source_crew_artifact_id: source_crew_artifact_id,
        expected_recipient_address: expected_recipient_address || preview.address,
        expected_inbound_message_id: expected_inbound_message_id || preview.inbound_message_id,
        confirmed_recipient_address: confirmed_recipient_address,
        transport: transport
      )
    end

    def raw_email(message_id: "root@example.net", references: nil, reply_to: nil, body: "Please help")
      headers = [
        "From: Alice Example <alice@example.net>",
        ("Reply-To: #{reply_to}" if reply_to),
        "To: Support <support@example.com>",
        "Date: Mon, 24 Aug 2026 11:55:00 +0000",
        "Subject: Email help",
        "Message-ID: <#{message_id}>",
        ("References: <#{references}>" if references),
        "MIME-Version: 1.0",
        "Content-Type: text/plain; charset=UTF-8"
      ].compact
      (headers + [ "", body ]).join("\r\n")
    end
end
