require "test_helper"

class SharedEmailInboxesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:acme_support)
  end

  test "owner lists and creates a workspace inbox with an audit event" do
    sign_in_as users(:owner)

    get workspace_shared_email_inboxes_path(@workspace)
    assert_response :success
    assert_select "h1", "Shared email inboxes"

    assert_difference [ "SharedEmailInbox.count", "AuditEvent.count" ], 1 do
      post workspace_shared_email_inboxes_path(@workspace), params: {
        shared_email_inbox: {
          name: "Support",
          email_address: "support@example.com",
          credential_key: "support"
        }
      }
    end

    assert_redirected_to workspace_shared_email_inboxes_path(@workspace)
    inbox = @workspace.shared_email_inboxes.sole
    assert_equal "support@example.com", inbox.email_address
    assert_equal "email.inbox_created", AuditEvent.order(:id).last.action

    get workspace_shared_email_inboxes_path(@workspace)
    assert_select ".status-badge", "Needs secret"
  end

  test "invalid inbox renders errors without an audit event" do
    sign_in_as users(:owner)

    assert_no_difference [ "SharedEmailInbox.count", "AuditEvent.count" ] do
      post workspace_shared_email_inboxes_path(@workspace), params: {
        shared_email_inbox: { name: "", email_address: "bad", credential_key: "Not valid" }
      }
    end

    assert_response :unprocessable_content
    assert_select ".inline-error"
  end

  test "owner pauses an inbox while manager and foreign workspace requests fail closed" do
    inbox = @workspace.shared_email_inboxes.create!(
      name: "Support", email_address: "support@example.com", credential_key: "support"
    )
    sign_in_as users(:owner)

    assert_difference "AuditEvent.count", 1 do
      patch workspace_shared_email_inbox_path(@workspace, inbox), params: {
        shared_email_inbox: { active: false }
      }
    end
    assert_not inbox.reload.active?

    sign_out
    sign_in_as users(:teammate)
    get workspace_shared_email_inboxes_path(workspaces(:acme_success))
    assert_response :forbidden

    sign_out
    sign_in_as users(:owner)
    patch workspace_shared_email_inbox_path(workspaces(:beta_support), inbox), params: {
      shared_email_inbox: { active: true }
    }
    assert_response :not_found
    assert_not inbox.reload.active?
  end

  test "owner sees and retries outstanding deliveries" do
    inbox = @workspace.shared_email_inboxes.create!(
      name: "Support", email_address: "support@example.com", credential_key: "support"
    )
    raw_email = <<~EMAIL
      From: Alice <alice@example.net>
      To: support@example.com
      Message-ID: <retry@example.net>
      Content-Type: text/plain; charset=UTF-8

      Please help.
    EMAIL
    delivery = inbox.inbound_email_deliveries.create!(
      workspace: @workspace,
      source_message_id: "retry@example.net",
      content_sha256: Digest::SHA256.hexdigest(raw_email),
      raw_email: raw_email,
      received_at: Time.current
    )
    sign_in_as users(:owner)

    get workspace_shared_email_inboxes_path(@workspace)
    assert_response :success
    assert_select "td", text: /1 delivery need retry/
    assert_select ".integration-failures", text: /Processing interrupted: 1/

    post reconcile_workspace_shared_email_inbox_path(@workspace, inbox)

    assert_redirected_to workspace_shared_email_inboxes_path(@workspace)
    assert delivery.reload.processed?
    retry_audit = AuditEvent.find_by!(action: "email.intake_retried", subject_id: delivery.id)
    assert_equal users(:owner), retry_audit.actor
    assert retry_audit.source_web?
  end

  test "terminal failures stay visible without offering a retry" do
    inbox = @workspace.shared_email_inboxes.create!(
      name: "Support", email_address: "support@example.com", credential_key: "support"
    )
    inbox.inbound_email_deliveries.create!(
      workspace: @workspace,
      source_message_id: "terminal@example.net",
      content_sha256: Digest::SHA256.hexdigest("terminal"),
      raw_email: "terminal",
      status: :failed,
      failure_code: "missing_sender",
      received_at: Time.current,
      processed_at: Time.current
    )
    sign_in_as users(:owner)

    get workspace_shared_email_inboxes_path(@workspace)

    assert_response :success
    assert_select "td", text: /1 delivery need review/
    assert_select ".integration-failures", text: /Missing sender: 1/
    assert_select "form[action='#{reconcile_workspace_shared_email_inbox_path(@workspace, inbox)}']", count: 0
  end

  test "manager cannot see or invoke inbox configuration" do
    membership = @workspace.memberships.create!(user: users(:teammate), role: :manager)
    inbox = @workspace.shared_email_inboxes.create!(
      name: "Support", email_address: "support@example.com", credential_key: "support"
    )
    sign_in_as membership.user

    get workspace_support_cases_path(@workspace)
    assert_response :success
    assert_select "a", { text: "Email", count: 0 }

    get workspace_shared_email_inboxes_path(@workspace)
    assert_response :forbidden
    post reconcile_workspace_shared_email_inbox_path(@workspace, inbox)
    assert_response :forbidden
  end
end
