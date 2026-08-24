require "test_helper"

class EmailRepliesControllerTest < ActionDispatch::IntegrationTest
  class RecordingTransport
    attr_reader :deliveries

    def initialize
      @deliveries = []
    end

    def deliver!(**attributes)
      @deliveries << attributes
    end
  end

  setup do
    @workspace = workspaces(:acme_support)
    @inbox = @workspace.shared_email_inboxes.create!(
      name: "Support",
      email_address: "support@example.com",
      credential_key: "support"
    )
    intake = SharedEmailIntake.receive!(
      inbox: @inbox,
      raw_email: raw_email,
      received_at: Time.zone.parse("2026-08-24 12:00:00 UTC")
    )
    @support_case = intake.conversation.support_case
    sign_in_as users(:owner)
  end

  test "a writer saves an editable draft" do
    assert_difference "EmailDraft.count", 1 do
      post email_draft_workspace_support_case_path(@workspace, @support_case), params: { body: "Draft answer", draft_version: "new" }
    end

    assert_redirected_to workspace_support_case_path(@workspace, @support_case, anchor: "email-reply")
    assert_equal "Draft answer", @support_case.email_draft.body
  end

  test "a fresh authenticated POST sends and attributes the exact content" do
    transport = RecordingTransport.new

    with_transport(transport) do
      assert_difference [ "OutboundEmailDelivery.sent.count", "ConversationMessage.outbound.count" ], 1 do
        post email_send_workspace_support_case_path(@workspace, @support_case),
          params: { body: "Exact reviewed answer", draft_version: "new", idempotency_key: "browser-send" }
      end
    end

    assert_redirected_to workspace_support_case_path(@workspace, @support_case)
    delivery = @workspace.outbound_email_deliveries.sole
    assert_equal "Exact reviewed answer", delivery.body
    assert_equal users(:owner), delivery.actor_user
    assert_equal 1, transport.deliveries.size
  end

  test "blank content returns 422 with the reply form preserved" do
    assert_no_difference [ "OutboundEmailDelivery.count", "ConversationMessage.outbound.count" ] do
      post email_send_workspace_support_case_path(@workspace, @support_case),
        params: { body: " ", draft_version: "new", idempotency_key: "blank-send" }
    end

    assert_response :unprocessable_content
    assert_select ".command-error[role='alert']", text: /can't be blank/i
    assert_select "textarea[name='body']", text: " "
  end

  test "a stale draft cannot overwrite or send a newer edit" do
    draft = EmailDraftWorkflow.save!(
      workspace: @workspace, support_case: @support_case,
      membership: memberships(:owner_support), body: "First edit", expected_lock_version: "new"
    )
    stale_version = draft.lock_version
    EmailDraftWorkflow.save!(
      workspace: @workspace, support_case: @support_case,
      membership: memberships(:owner_support), body: "Newer edit", expected_lock_version: stale_version.to_s
    )
    transport = RecordingTransport.new

    with_transport(transport) do
      assert_no_difference [ "OutboundEmailDelivery.count", "ConversationMessage.outbound.count", "AuditEvent.count" ] do
        post email_send_workspace_support_case_path(@workspace, @support_case),
          params: { body: "Stale edit", draft_version: stale_version, idempotency_key: "stale-send" }
      end
    end

    assert_response :unprocessable_content
    assert_select ".command-error", text: /changed in another session/i
    assert_select "textarea[name='body']", text: "Newer edit"
    assert_empty transport.deliveries
  end

  test "viewer draft and send forgeries return 403 before transport" do
    viewer = User.create!(email_address: "email-viewer@example.com", password: "password12345", verified_at: Time.current)
    Membership.create!(workspace: @workspace, user: viewer, role: :viewer)
    sign_in_as viewer
    transport = RecordingTransport.new

    assert_no_difference [ "EmailDraft.count", "OutboundEmailDelivery.count", "AuditEvent.count" ] do
      post email_draft_workspace_support_case_path(@workspace, @support_case), params: { body: "Forged draft", draft_version: "new" }
    end
    assert_response :forbidden

    with_transport(transport) do
      assert_no_difference [ "OutboundEmailDelivery.count", "ConversationMessage.outbound.count", "AuditEvent.count" ] do
        post email_send_workspace_support_case_path(@workspace, @support_case),
          params: { body: "Forged send", draft_version: "new", idempotency_key: "viewer-send" }
      end
    end
    assert_response :forbidden
    assert_empty transport.deliveries
  end

  test "an expired session is redirected to authentication without sending" do
    Current.session.update!(expires_at: 1.minute.ago)

    assert_no_difference [ "OutboundEmailDelivery.count", "ConversationMessage.outbound.count" ] do
      post email_send_workspace_support_case_path(@workspace, @support_case),
        params: { body: "Expired", draft_version: "new", idempotency_key: "expired-send" }
    end

    assert_redirected_to new_session_path
  end

  test "a foreign case fails closed" do
    foreign_case = create_support_case(
      workspace: workspaces(:beta_support), contact: contacts(:bob), membership: memberships(:outsider_beta)
    )

    post email_send_workspace_support_case_path(@workspace, foreign_case),
      params: { body: "Foreign", draft_version: "new", idempotency_key: "foreign-send" }

    assert_response :not_found
  end

  private
    def with_transport(transport)
      singleton = SharedEmailSmtpTransport.singleton_class
      singleton.alias_method :new_without_test_transport, :new
      singleton.define_method(:new) { transport }
      yield
    ensure
      singleton.alias_method :new, :new_without_test_transport
      singleton.remove_method :new_without_test_transport
    end

    def raw_email
      <<~EMAIL.gsub("\n", "\r\n")
        From: Alice Example <alice@example.net>
        To: Support <support@example.com>
        Date: Mon, 24 Aug 2026 11:55:00 +0000
        Subject: Email help
        Message-ID: <controller-root@example.net>
        MIME-Version: 1.0
        Content-Type: text/plain; charset=UTF-8

        Please help
      EMAIL
    end
end
