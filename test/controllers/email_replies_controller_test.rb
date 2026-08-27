require "test_helper"

class EmailRepliesControllerTest < ActionDispatch::IntegrationTest
  class RecordingTransport
    attr_reader :deliveries

    def initialize(error: nil)
      @error = error
      @deliveries = []
    end

    def deliver!(**attributes)
      @deliveries << attributes
      raise @error if @error
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

    get workspace_support_case_path(@workspace, @support_case)
    assert_select "#email-draft-provenance", text: /Human-authored draft/
    assert_select "#email-reply input[name='source_crew_artifact_id']", count: 0
  end

  test "a writer explicitly adopts and then edits a blocked Crew draft" do
    artifact = create_draft_artifact(
      workspace: @workspace, support_case: @support_case, membership: memberships(:owner_support),
      body: "Exact generated email body", result_state: "blocked", evidence_status: "stale",
      blocker_message: "Reset policy evidence is stale.",
      remediation: "Refresh the reset policy source and run the specialist again."
    )

    get workspace_support_case_path(@workspace, @support_case)

    assert_response :success
    assert_select "#email-reply .draft-source-form" do
      assert_select "input[name='source_crew_artifact_id'][value='#{artifact.id}']"
      assert_select "input[name='adopt_source'][value='1']"
      assert_select "input[type='submit'][value='Use this AI draft']"
    end
    assert_select "#email-reply", text: /Reset policy evidence is stale\./
    assert_select "#email-reply", text: /Refresh the reset policy source and run the specialist again\./
    assert_select "#email-reply", text: /Stale conversation/

    post email_draft_workspace_support_case_path(@workspace, @support_case), params: {
      body: artifact.body, draft_version: "new", source_crew_artifact_id: artifact.id, adopt_source: "1"
    }
    assert_redirected_to workspace_support_case_path(@workspace, @support_case, anchor: "email-reply")
    draft = @support_case.reload.email_draft
    assert_equal artifact, draft.source_crew_artifact
    assert_nil draft.human_edited_at

    get workspace_support_case_path(@workspace, @support_case)
    assert_select "#email-draft-provenance", text: /AI source · Generated body/
    assert_select "#email-reply input[name='source_crew_artifact_id'][value='#{artifact.id}']"

    post email_draft_workspace_support_case_path(@workspace, @support_case), params: {
      body: "Human-qualified email body", draft_version: draft.lock_version,
      source_crew_artifact_id: artifact.id
    }
    assert_redirected_to workspace_support_case_path(@workspace, @support_case, anchor: "email-reply")

    get workspace_support_case_path(@workspace, @support_case)
    assert_select "#email-draft-provenance", text: /AI source · Human-edited/
    assert_select "#email-draft-provenance", text: /Edited by owner@example\.com/
    assert_select "#email-draft-provenance", text: /replacement text does not inherit its grounding/
  end

  test "a fresh authenticated POST sends and attributes the exact content" do
    transport = RecordingTransport.new

    with_transport(transport) do
      assert_difference [ "OutboundEmailDelivery.sent.count", "ConversationMessage.outbound.count" ], 1 do
        post email_send_workspace_support_case_path(@workspace, @support_case),
          params: recipient_binding.merge(body: "Exact reviewed answer", draft_version: "new", idempotency_key: "browser-send")
      end
    end

    assert_redirected_to workspace_support_case_path(@workspace, @support_case)
    delivery = @workspace.outbound_email_deliveries.sole
    assert_equal "Exact reviewed answer", delivery.body
    assert_equal users(:owner), delivery.actor_user
    assert_equal 1, transport.deliveries.size
  end

  test "an untrusted Reply-To is shown and requires an explicit recipient check" do
    intake = SharedEmailIntake.receive!(
      inbox: @inbox,
      raw_email: raw_email(
        message_id: "external-reply-to@example.net",
        reply_to: "third-party@example.org"
      ),
      received_at: Time.zone.parse("2026-08-24 12:05:00 UTC")
    )
    support_case = intake.conversation.support_case
    get workspace_support_case_path(@workspace, support_case)
    assert_response :success
    assert_select ".recipient-review-warning", text: /third-party@example\.org/
    assert_select "input[name='confirmed_recipient_address'][value='third-party@example.org'][required]"
    binding = recipient_binding(support_case)
    assert_select "input[name='expected_recipient_address'][value='third-party@example.org']"
    assert_select "input[name='expected_inbound_message_id'][value='external-reply-to@example.net']"

    transport = RecordingTransport.new
    with_transport(transport) do
      assert_no_difference "OutboundEmailDelivery.count" do
        post email_send_workspace_support_case_path(@workspace, support_case), params: binding.merge(
          body: "Checked answer", draft_version: "new", idempotency_key: "unchecked-recipient"
        )
      end
      assert_response :unprocessable_content

      post email_send_workspace_support_case_path(@workspace, support_case), params: binding.merge(
        body: "Checked answer", draft_version: "new", idempotency_key: "checked-recipient",
        confirmed_recipient_address: "third-party@example.org"
      )
    end
    assert_redirected_to workspace_support_case_path(@workspace, support_case)
    assert_equal "third-party@example.org", transport.deliveries.sole[:to]
  end

  test "a new inbound after render blocks the stale recipient and parent binding" do
    binding = recipient_binding
    SharedEmailIntake.receive!(
      inbox: @inbox,
      raw_email: raw_email(
        message_id: "new-after-render@example.net",
        references: "controller-root@example.net"
      ),
      received_at: Time.zone.parse("2026-08-24 12:05:00 UTC")
    )
    transport = RecordingTransport.new

    with_transport(transport) do
      assert_no_difference [ "OutboundEmailDelivery.count", "ConversationMessage.outbound.count" ] do
        post email_send_workspace_support_case_path(@workspace, @support_case), params: binding.merge(
          body: "Stale page reply", draft_version: "new", idempotency_key: "stale-conversation"
        )
      end
    end

    assert_response :unprocessable_content
    assert_select ".command-error", text: /new customer message/i
    assert_empty transport.deliveries
  end

  test "a writer uploads and removes a quarantined draft attachment" do
    draft = EmailDraftWorkflow.save!(
      workspace: @workspace, support_case: @support_case,
      membership: memberships(:owner_support), body: "Draft answer", expected_lock_version: "new"
    )

    assert_difference [ "StoredAttachment.count", "EmailDraftAttachment.count" ], 1 do
      post email_attachments_workspace_support_case_path(@workspace, @support_case), params: {
        draft_version: draft.lock_version,
        files: [ uploaded_file("notes.txt", "private notes") ]
      }
    end

    attachment = draft.reload.stored_attachments.sole
    assert attachment.quarantined?
    assert_redirected_to workspace_support_case_path(@workspace, @support_case, anchor: "email-reply")

    assert_difference "EmailDraftAttachment.count", -1 do
      delete email_attachment_workspace_support_case_path(@workspace, @support_case, attachment), params: {
        draft_version: draft.lock_version
      }
    end
    assert_redirected_to workspace_support_case_path(@workspace, @support_case, anchor: "email-reply")
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

  test "a fresh writer reviews an unknown outcome while a viewer cannot forge it" do
    transport = RecordingTransport.new(error: Net::ReadTimeout.new("timeout"))
    with_transport(transport) do
      post email_send_workspace_support_case_path(@workspace, @support_case),
        params: recipient_binding.merge(body: "Uncertain send", draft_version: "new", idempotency_key: "uncertain-send")
    end
    delivery = @workspace.outbound_email_deliveries.sole
    assert delivery.unknown?

    get workspace_support_case_path(@workspace, @support_case)
    assert_select ".delivery-review-facts", text: /alice@example\.net/
    assert_select ".delivery-review-facts", text: /#{Regexp.escape(delivery.message_id)}/
    assert_select ".delivery-review-body", text: /Uncertain send/

    viewer = User.create!(email_address: "delivery-review-viewer@example.com", password: "password12345", verified_at: Time.current)
    Membership.create!(workspace: @workspace, user: viewer, role: :viewer)
    sign_in_as viewer
    assert_no_difference [ "ConversationMessage.outbound.count", "AuditEvent.count" ] do
      post email_delivery_review_workspace_support_case_path(@workspace, @support_case, delivery), params: { outcome: "accepted" }
    end
    assert_response :forbidden
    assert delivery.reload.unknown?

    sign_in_as users(:owner)
    post email_delivery_review_workspace_support_case_path(@workspace, @support_case, delivery), params: { outcome: "rejected" }
    assert_redirected_to workspace_support_case_path(@workspace, @support_case, anchor: "email-reply")
    assert delivery.reload.failed?
    assert delivery.email_draft.reload.ready?

    post email_delivery_review_workspace_support_case_path(@workspace, @support_case, delivery), params: { outcome: "accepted" }
    assert_response :unprocessable_content
    assert_select ".command-error", text: /opposite outcome/i
    assert delivery.reload.failed?
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

  test "viewer and stale attachment forgeries leave no records or blobs" do
    draft = EmailDraftWorkflow.save!(
      workspace: @workspace, support_case: @support_case,
      membership: memberships(:owner_support), body: "Draft answer", expected_lock_version: "new"
    )
    viewer = User.create!(email_address: "attachment-controller-viewer@example.com", password: "password12345", verified_at: Time.current)
    Membership.create!(workspace: @workspace, user: viewer, role: :viewer)
    sign_in_as viewer

    assert_no_difference [ "StoredAttachment.count", "ActiveStorage::Blob.count", "AuditEvent.count" ] do
      post email_attachments_workspace_support_case_path(@workspace, @support_case), params: {
        draft_version: draft.lock_version,
        files: [ uploaded_file("forged.txt", "forged") ]
      }
    end
    assert_response :forbidden

    sign_in_as users(:owner)
    assert_no_difference [ "StoredAttachment.count", "ActiveStorage::Blob.count", "AuditEvent.count" ] do
      post email_attachments_workspace_support_case_path(@workspace, @support_case), params: {
        draft_version: -1,
        files: [ uploaded_file("stale.txt", "stale") ]
      }
    end
    assert_response :unprocessable_content
    assert_select ".command-error", text: /changed in another session/i
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
    def recipient_binding(support_case = @support_case)
      preview = HumanEmailSend.recipient_preview(workspace: @workspace, support_case: support_case)
      {
        expected_recipient_address: preview.address,
        expected_inbound_message_id: preview.inbound_message_id
      }
    end

    def uploaded_file(filename, content)
      Rack::Test::UploadedFile.new(
        StringIO.new(content.dup), "application/octet-stream", true,
        original_filename: filename
      )
    end

    def with_transport(transport)
      singleton = SharedEmailSmtpTransport.singleton_class
      singleton.alias_method :new_without_test_transport, :new
      singleton.define_method(:new) { transport }
      yield
    ensure
      singleton.alias_method :new, :new_without_test_transport
      singleton.remove_method :new_without_test_transport
    end

    def raw_email(message_id: "controller-root@example.net", reply_to: nil, references: nil)
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
      (headers + [ "", "Please help" ]).join("\r\n")
    end
end
