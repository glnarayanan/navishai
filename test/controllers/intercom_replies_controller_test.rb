require "test_helper"

class IntercomRepliesControllerTest < ActionDispatch::IntegrationTest
  class FakeClient
    attr_reader :replies

    def initialize
      @replies = []
    end

    def admins
      { "admins" => [ { "id" => "admin_owner", "email" => "owner@example.com" } ] }
    end

    def reply(conversation_id:, admin_id:, body:)
      @replies << { conversation_id:, admin_id:, body: }
      {
        "id" => conversation_id, "conversation_parts" => { "conversation_parts" => [
          {
            "id" => "sent_from_controller", "part_type" => "comment", "body" => "<p>#{body}</p>",
            "created_at" => Time.current.to_i,
            "author" => { "type" => "admin", "id" => admin_id, "name" => "Owner" }
          }
        ] }
      }
    end
  end

  setup do
    @workspace = workspaces(:acme_support)
    message = ConversationThread.start_inbound!(
      workspace: @workspace, contact: contacts(:alice), subject: "Intercom help",
      body: "Please help", occurred_at: 1.minute.ago, source: :integration
    )
    @support_case = message.conversation.support_case
    @connection = @workspace.intercom_connections.create!(
      name: "Support Intercom", remote_workspace_id: "app_controller", credential_key: "support"
    )
    @link = @connection.intercom_conversation_links.create!(
      workspace: @workspace, conversation: message.conversation, support_case: @support_case,
      remote_conversation_id: "controller_conversation", remote_state: "open",
      source_digest: "a" * 64, remote_updated_at: message.occurred_at, synced_at: message.occurred_at
    )
    @connection.intercom_part_links.create!(
      workspace: @workspace, intercom_conversation_link: @link, conversation: message.conversation,
      conversation_message: message, remote_part_id: "controller_customer", part_type: :contact_reply,
      body: message.body, source_digest: "b" * 64, remote_created_at: message.occurred_at
    )
    sign_in_as users(:owner)
  end

  test "the case shows the exact binding and a fresh human POST sends once" do
    get workspace_support_case_path(@workspace, @support_case)
    assert_response :success
    assert_select "#intercom-reply input[name='expected_source_part_id'][value='controller_customer']"
    assert_select "#intercom-reply", text: /Agents and jobs cannot send it/
    client = FakeClient.new

    with_client(client) do
      assert_difference [ "IntercomOutboundDelivery.sent.count", "ConversationMessage.outbound.count" ], 1 do
        post intercom_send_workspace_support_case_path(@workspace, @support_case), params: {
          body: "Exact Intercom answer", draft_version: "new", idempotency_key: "controller-send",
          expected_source_part_id: "controller_customer"
        }
      end
    end

    assert_redirected_to workspace_support_case_path(@workspace, @support_case)
    assert_equal "Exact Intercom answer", @workspace.intercom_outbound_deliveries.sole.body
    assert_equal 1, client.replies.size
  end

  test "a stale binding returns 422 without contacting Intercom" do
    latest = ConversationThread.append_inbound!(
      workspace: @workspace, conversation: @link.conversation, author: @link.conversation.contact,
      body: "New reply", occurred_at: Time.current, source: :integration
    )
    @connection.intercom_part_links.create!(
      workspace: @workspace, intercom_conversation_link: @link, conversation: @link.conversation,
      conversation_message: latest, remote_part_id: "new_controller_customer", part_type: :contact_reply,
      body: latest.body, source_digest: "c" * 64, remote_created_at: latest.occurred_at
    )
    client = FakeClient.new

    with_client(client) do
      assert_no_difference "IntercomOutboundDelivery.count" do
        post intercom_send_workspace_support_case_path(@workspace, @support_case), params: {
          body: "Stale answer", draft_version: "new", idempotency_key: "stale-controller",
          expected_source_part_id: "controller_customer"
        }
      end
    end

    assert_response :unprocessable_content
    assert_select ".command-error", text: /conversation changed/i
    assert_empty client.replies
    assert_select "input[name='expected_source_part_id'][value='new_controller_customer']"
  end

  test "a viewer cannot save or send a draft" do
    viewer = User.create!(email_address: "controller-viewer@example.com", password: "password12345", verified_at: Time.current)
    @workspace.memberships.create!(user: viewer, role: :viewer)
    sign_in_as viewer
    client = FakeClient.new

    assert_no_difference [ "IntercomDraft.count", "IntercomOutboundDelivery.count", "AuditEvent.count" ] do
      post intercom_draft_workspace_support_case_path(@workspace, @support_case), params: {
        body: "Forged draft", draft_version: "new"
      }
    end
    assert_response :forbidden

    with_client(client) do
      assert_no_difference [ "IntercomDraft.count", "IntercomOutboundDelivery.count", "AuditEvent.count" ] do
        post intercom_send_workspace_support_case_path(@workspace, @support_case), params: {
          body: "Forged reply", draft_version: "new", idempotency_key: "viewer-controller",
          expected_source_part_id: "controller_customer"
        }
      end
    end
    assert_response :forbidden
    assert_empty client.replies
  end

  private
    def with_client(client)
      original = IntercomClient.method(:new)
      IntercomClient.define_singleton_method(:new) { |**| client }
      yield
    ensure
      IntercomClient.define_singleton_method(:new, original)
    end
end
