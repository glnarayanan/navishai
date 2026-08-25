require "test_helper"

class SharedEmailIntakeTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:acme_support)
    @inbox = @workspace.shared_email_inboxes.create!(
      name: "Support",
      email_address: "support@example.com",
      credential_key: "support"
    )
    @received_at = Time.zone.parse("2026-08-24 12:00:00 UTC")
  end

  test "receives a plain email into a new contact conversation and case" do
    raw = raw_email(message_id: "root@example.net", body: "I cannot sign in.")

    assert_difference [ "Contact.count", "Conversation.count", "SupportCase.count", "ConversationMessage.count" ], 1 do
      @delivery = SharedEmailIntake.receive!(inbox: @inbox, raw_email: raw, received_at: @received_at)
    end

    assert @delivery.processed?
    assert_equal raw.b, @delivery.raw_email
    assert_equal "alice@example.net", @delivery.conversation.contact.source_identities.sole.source_record_id
    assert_equal "I cannot sign in.", @delivery.conversation_message.body
    assert_equal "Email help", @delivery.conversation.subject
    assert_equal "new", @delivery.conversation.support_case.status
    assert_equal "root@example.net", @inbox.email_message_links.sole.message_id
    assert AuditEvent.where(action: "email.intake_received", subject_id: @delivery.id).exists?
  end

  test "threads replies and out-of-order parents by the root reference" do
    child = raw_email(
      message_id: "child@example.net",
      references: "<root@example.net>",
      body: "Following up first"
    )
    root = raw_email(message_id: "root@example.net", body: "Original arrived later")

    child_delivery = SharedEmailIntake.receive!(inbox: @inbox, raw_email: child, received_at: @received_at)
    root_delivery = SharedEmailIntake.receive!(inbox: @inbox, raw_email: root, received_at: @received_at + 1.minute)

    assert_equal child_delivery.conversation, root_delivery.conversation
    assert_equal 2, child_delivery.conversation.conversation_messages.count
    assert_equal 1, @inbox.email_threads.count
    assert_equal "root@example.net", @inbox.email_threads.sole.thread_key
  end

  test "threads a reply that has only an in-reply-to parent" do
    root = SharedEmailIntake.receive!(
      inbox: @inbox,
      raw_email: raw_email(message_id: "root@example.net"),
      received_at: @received_at
    )
    reply = SharedEmailIntake.receive!(
      inbox: @inbox,
      raw_email: raw_email(message_id: "reply@example.net", in_reply_to: "<root@example.net>"),
      received_at: @received_at + 1.minute
    )

    assert_equal root.conversation, reply.conversation
    assert_equal 2, root.conversation.conversation_messages.count
    assert_equal 1, @inbox.email_threads.count
  end

  test "suppresses exact duplicates and rejects message id reuse" do
    raw = raw_email(message_id: "duplicate@example.net")
    original = SharedEmailIntake.receive!(inbox: @inbox, raw_email: raw, received_at: @received_at)

    assert_no_difference [ "InboundEmailDelivery.count", "ConversationMessage.count", "AuditEvent.count" ] do
      assert_equal original, SharedEmailIntake.receive!(inbox: @inbox, raw_email: raw, received_at: @received_at)
    end

    changed = raw_email(message_id: "duplicate@example.net", body: "Changed content")
    assert_difference -> { InboundEmailDelivery.where(failure_code: "message_id_conflict").count }, 1 do
      assert_raises(SharedEmailIntake::Conflict) do
        SharedEmailIntake.receive!(inbox: @inbox, raw_email: changed, received_at: @received_at)
      end
    end
    conflict = @inbox.inbound_email_deliveries.find_by!(failure_code: "message_id_conflict")
    assert_equal "duplicate@example.net", conflict.source_message_id
    assert_equal Digest::SHA256.hexdigest(changed), conflict.content_sha256
    assert AuditEvent.where(action: "email.intake_failed", subject_id: conflict.id).exists?
  end

  test "malformed reference tokens cannot merge unrelated conversations" do
    first = SharedEmailIntake.receive!(
      inbox: @inbox, raw_email: raw_email(message_id: "first@example.net", references: "newsletter weekly"),
      received_at: @received_at
    )
    second = SharedEmailIntake.receive!(
      inbox: @inbox, raw_email: raw_email(message_id: "second@example.net", references: "newsletter weekly"),
      received_at: @received_at + 1.minute
    )

    refute_equal first.conversation, second.conversation
    assert_equal 2, @inbox.email_threads.count
  end

  test "a reply stays on its conversation after the stored contact is merged" do
    root = SharedEmailIntake.receive!(
      inbox: @inbox, raw_email: raw_email(message_id: "merged-root@example.net"),
      received_at: @received_at
    )
    original_contact = root.conversation.contact
    canonical_contact = @workspace.contacts.create!(name: "Canonical customer")
    CustomerRecordMerger.merge!(
      workspace: @workspace, source: original_contact, target: canonical_contact,
      membership: memberships(:owner_support)
    )

    reply = SharedEmailIntake.receive!(
      inbox: @inbox,
      raw_email: raw_email(message_id: "merged-reply@example.net", references: "<merged-root@example.net>"),
      received_at: @received_at + 1.minute
    )

    assert reply.processed?
    assert_equal root.conversation, reply.conversation
    assert_equal original_contact, reply.conversation_message.author_contact
    assert_equal canonical_contact, reply.conversation_message.author_contact.canonical
  end

  test "receipt time controls case and message ordering instead of sender date" do
    delivery = SharedEmailIntake.receive!(
      inbox: @inbox, raw_email: raw_email(message_id: "old-date@example.net", date: 10.years.ago),
      received_at: @received_at
    )

    assert_equal @received_at, delivery.conversation_message.occurred_at
    assert_equal @received_at, delivery.conversation.started_at
    assert_equal @received_at, delivery.conversation.support_case.status_changed_at
  end

  test "a delayed sender date cannot suppress a reopen after trusted receipt" do
    received_at = Time.current - 2.hours
    root = SharedEmailIntake.receive!(
      inbox: @inbox, raw_email: raw_email(message_id: "reopen-root@example.net"), received_at: received_at
    )
    support_case = root.conversation.support_case
    actor = memberships(:owner_support)
    transitions = [
      [ "triaged", received_at + 10.minutes ],
      [ "investigating", received_at + 20.minutes ],
      [ "resolved", received_at + 30.minutes ],
      [ "closed", received_at + 40.minutes ]
    ]
    transitions.each do |status, at|
      CaseWorkflow.transition!(
        workspace: @workspace, support_case: support_case, membership: actor,
        to: status, reason: "test transition", occurred_at: at
      )
    end

    reply = SharedEmailIntake.receive!(
      inbox: @inbox,
      raw_email: raw_email(
        message_id: "reopen-reply@example.net", references: "<reopen-root@example.net>",
        date: received_at - 1.day
      ),
      received_at: received_at + 1.hour
    )

    assert reply.processed?
    assert_equal "investigating", support_case.reload.status
    assert_equal (received_at + 1.hour).to_i, support_case.status_changed_at.to_i
  end

  test "unnamed attachment parts never enter the customer message body" do
    boundary = "navishai-boundary"
    raw = raw_email(
      message_id: "attachment@example.net",
      content_type: "multipart/mixed; boundary=#{boundary}",
      body: [
        "--#{boundary}", "Content-Type: text/plain; charset=UTF-8", "", "Visible request",
        "--#{boundary}", "Content-Type: text/plain; charset=UTF-8", "Content-Disposition: attachment", "", "ATTACHMENT SECRET",
        "--#{boundary}--", ""
      ].join("\r\n")
    )

    delivery = SharedEmailIntake.receive!(inbox: @inbox, raw_email: raw, received_at: @received_at)

    assert_equal "Visible request", delivery.conversation_message.body
    refute_includes delivery.conversation_message.body, "ATTACHMENT SECRET"
  end

  test "permanent failures cannot starve received reconciliation work" do
    100.times do |index|
      raw = raw_email(message_id: "permanent-#{index}@example.net").sub(/From:.*\r\n/, "")
      @inbox.inbound_email_deliveries.create!(
        workspace: @workspace, source_message_id: "permanent-#{index}@example.net",
        content_sha256: Digest::SHA256.hexdigest(raw), raw_email: raw,
        status: :failed, failure_code: "missing_sender",
        received_at: @received_at - 1.day, processed_at: @received_at
      )
    end
    valid = raw_email(message_id: "not-starved@example.net")
    received = @inbox.inbound_email_deliveries.create!(
      workspace: @workspace, source_message_id: "not-starved@example.net",
      content_sha256: Digest::SHA256.hexdigest(valid), raw_email: valid, received_at: @received_at
    )

    assert_includes SharedEmailIntake.reconcile!(inbox: @inbox, membership: memberships(:owner_support)), received
    assert received.reload.processed?
    assert AuditEvent.where(action: "email.intake_retried", actor: users(:owner), subject_id: received.id).exists?
  end

  test "reconciliation bounds repeated retryable failures" do
    raw = raw_email(message_id: "bounded@example.net")
    delivery = @inbox.inbound_email_deliveries.create!(
      workspace: @workspace, source_message_id: "bounded@example.net",
      content_sha256: Digest::SHA256.hexdigest(raw), raw_email: raw,
      status: :failed, failure_code: "persistence_error",
      attempt_count: SharedEmailIntake::MAX_RECONCILIATION_ATTEMPTS,
      last_attempted_at: @received_at,
      received_at: @received_at, processed_at: @received_at
    )

    refute_includes SharedEmailIntake.reconcile!(inbox: @inbox, membership: memberships(:owner_support)), delivery
    assert_equal SharedEmailIntake::MAX_RECONCILIATION_ATTEMPTS, delivery.reload.attempt_count
  end

  test "records safe failures and can reconcile a failed valid delivery" do
    invalid = raw_email(message_id: nil)
    failed = SharedEmailIntake.receive!(inbox: @inbox, raw_email: invalid, received_at: @received_at)

    assert failed.failed?
    assert_equal "missing_message_id", failed.failure_code
    assert_nil failed.conversation
    assert AuditEvent.where(action: "email.intake_failed", subject_id: failed.id).exists?

    valid = raw_email(message_id: "retry@example.net")
    retry_delivery = @inbox.inbound_email_deliveries.create!(
      workspace: @workspace,
      source_message_id: "retry@example.net",
      content_sha256: Digest::SHA256.hexdigest(valid),
      raw_email: valid,
      status: :failed,
      failure_code: "persistence_error",
      received_at: @received_at,
      processed_at: @received_at
    )

    assert_includes SharedEmailIntake.reconcile!(inbox: @inbox, membership: memberships(:owner_support)), retry_delivery
    assert retry_delivery.reload.processed?
  end

  test "records safe failure codes for invalid message content" do
    missing_sender = raw_email(message_id: "missing-sender@example.net").sub(/From:.*\r\n/, "")
    empty_body = raw_email(message_id: "empty@example.net", body: "")
    large_body = raw_email(message_id: "large@example.net", body: "x" * (SharedEmailIntake::MAX_BODY_BYTES + 1))

    sender_delivery = SharedEmailIntake.receive!(inbox: @inbox, raw_email: missing_sender, received_at: @received_at)
    body_delivery = SharedEmailIntake.receive!(inbox: @inbox, raw_email: empty_body, received_at: @received_at)
    large_delivery = SharedEmailIntake.receive!(inbox: @inbox, raw_email: large_body, received_at: @received_at)

    assert_equal "missing_sender", sender_delivery.failure_code
    assert_equal "empty_body", body_delivery.failure_code
    assert_equal "body_too_large", large_delivery.failure_code
    assert_nil sender_delivery.conversation
    assert_nil body_delivery.conversation
    assert_nil large_delivery.conversation
  end

  test "reconciliation also completes a received delivery left by interrupted processing" do
    raw = raw_email(message_id: "received@example.net")
    delivery = @inbox.inbound_email_deliveries.create!(
      workspace: @workspace,
      source_message_id: "received@example.net",
      content_sha256: Digest::SHA256.hexdigest(raw),
      raw_email: raw,
      received_at: @received_at
    )

    assert_includes SharedEmailIntake.reconcile!(inbox: @inbox, membership: memberships(:owner_support)), delivery
    assert delivery.reload.processed?
  end

  test "each inbox owns its source namespace while deterministic email matching reuses the contact" do
    second_inbox = @workspace.shared_email_inboxes.create!(
      name: "Billing",
      email_address: "billing@example.com",
      credential_key: "billing"
    )

    first = SharedEmailIntake.receive!(
      inbox: @inbox,
      raw_email: raw_email(message_id: "support@example.net"),
      received_at: @received_at
    )
    second = SharedEmailIntake.receive!(
      inbox: second_inbox,
      raw_email: raw_email(message_id: "billing@example.net"),
      received_at: @received_at
    )

    assert_equal first.conversation.contact, second.conversation.contact
    assert_equal 2, first.conversation.contact.source_identities.count
    expected_namespaces = [ "shared_email:#{@inbox.id}", "shared_email:#{second_inbox.id}" ]
    assert_equal expected_namespaces.sort,
      first.conversation.contact.source_identities.pluck(:source_namespace).sort
  end

  test "renders HTML as plain text" do
    raw = raw_email(
      message_id: "html@example.net",
      date: @received_at + 1.day,
      content_type: "text/html; charset=UTF-8",
      body: "<p>Hello <strong>team</strong></p><script>alert('x')</script>"
    )

    delivery = SharedEmailIntake.receive!(inbox: @inbox, raw_email: raw, received_at: @received_at)

    assert_equal "Hello team", delivery.conversation_message.body
    assert_equal @received_at, delivery.conversation_message.occurred_at
    refute_includes delivery.conversation_message.body, "<"
  end

  test "database triggers preserve raw source and thread mappings" do
    delivery = SharedEmailIntake.receive!(
      inbox: @inbox,
      raw_email: raw_email(message_id: "durable@example.net"),
      received_at: @received_at
    )

    assert_raises(ActiveRecord::StatementInvalid) do
      InboundEmailDelivery.where(id: delivery.id).update_all(raw_email: "changed")
    end
  end

  test "database triggers reject deleting message links" do
    SharedEmailIntake.receive!(
      inbox: @inbox,
      raw_email: raw_email(message_id: "linked@example.net"),
      received_at: @received_at
    )

    assert_raises(ActiveRecord::StatementInvalid) { EmailMessageLink.delete_all }
  end


  test "database trigger locks a processed delivery state" do
    delivery = SharedEmailIntake.receive!(
      inbox: @inbox,
      raw_email: raw_email(message_id: "final@example.net"),
      received_at: @received_at
    )

    assert_raises(ActiveRecord::StatementInvalid) do
      InboundEmailDelivery.transaction(requires_new: true) do
        InboundEmailDelivery.where(id: delivery.id).update_all(status: "failed", failure_code: "persistence_error")
      end
    end
    assert delivery.reload.processed?
  end

  private
    def raw_email(message_id:, body: "Please help", references: nil, in_reply_to: nil, date: @received_at - 5.minutes, content_type: "text/plain; charset=UTF-8", from: "Alice Example <alice@example.net>")
      headers = [
        "From: #{from}",
        "To: Support <support@example.com>",
        "Date: #{date.rfc2822}",
        "Subject: Email help",
        ("Message-ID: <#{message_id}>" if message_id),
        ("References: #{references}" if references),
        ("In-Reply-To: #{in_reply_to}" if in_reply_to),
        "MIME-Version: 1.0",
        "Content-Type: #{content_type}"
      ].compact
      "#{headers.join("\r\n")}\r\n\r\n#{body}\r\n"
    end
end
