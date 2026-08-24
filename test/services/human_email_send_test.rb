require "test_helper"

class HumanEmailSendTest < ActiveSupport::TestCase
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
    def send_email(support_case: @support_case, key: "send-key", draft_version: "new", transport: RecordingTransport.new)
      HumanEmailSend.send!(
        workspace: @workspace,
        support_case: support_case,
        membership: @membership,
        body: "A human reply",
        draft_version: draft_version,
        idempotency_key: key,
        transport: transport
      )
    end

    def raw_email(message_id: "root@example.net")
      <<~EMAIL.gsub("\n", "\r\n")
        From: Alice Example <alice@example.net>
        To: Support <support@example.com>
        Date: Mon, 24 Aug 2026 11:55:00 +0000
        Subject: Email help
        Message-ID: <#{message_id}>
        MIME-Version: 1.0
        Content-Type: text/plain; charset=UTF-8

        Please help
      EMAIL
    end
end
