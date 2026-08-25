require "test_helper"

class IntercomTenancyTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:acme_support)
    @connection = @workspace.intercom_connections.create!(
      name: "Support Intercom", remote_workspace_id: "app_123", credential_key: "support"
    )
  end

  test "database rejects a cross-workspace conversation mapping" do
    foreign_case = create_support_case(
      workspace: workspaces(:beta_support), contact: contacts(:bob), membership: memberships(:outsider_beta)
    )

    assert_raises ActiveRecord::StatementInvalid do
      IntercomConversationLink.transaction(requires_new: true) do
        IntercomConversationLink.insert!({
          workspace_id: foreign_case.workspace_id,
          intercom_connection_id: @connection.id,
          conversation_id: foreign_case.conversation_id,
          support_case_id: foreign_case.id,
          remote_conversation_id: "foreign", remote_state: "open", source_digest: "a" * 64,
          remote_updated_at: Time.current, synced_at: Time.current,
          created_at: Time.current, updated_at: Time.current
        })
      end
    end
  end

  test "database freezes the original webhook source" do
    delivery = @connection.intercom_webhook_deliveries.create!(
      workspace: @workspace, notification_id: "notification_1", topic: "ping",
      content_sha256: Digest::SHA256.hexdigest("{}"), raw_payload: "{}",
      received_at: Time.current
    )

    assert_raises ActiveRecord::StatementInvalid do
      delivery.transaction(requires_new: true) { delivery.update_column(:raw_payload, "changed") }
    end
    assert_equal "{}", delivery.reload.raw_payload
  end
end
