require "test_helper"

class SharedEmailTenancyTest < ActiveSupport::TestCase
  setup do
    @acme = workspaces(:acme_support)
    @beta = workspaces(:beta_support)
    @acme_inbox = @acme.shared_email_inboxes.create!(
      name: "Acme Support", email_address: "support@acme.example", credential_key: "acme"
    )
    @beta_inbox = @beta.shared_email_inboxes.create!(
      name: "Beta Support", email_address: "support@beta.example", credential_key: "beta"
    )
    @acme_message = ConversationThread.start_inbound!(
      workspace: @acme, contact: contacts(:alice), subject: "Acme", body: "Help",
      occurred_at: Time.current, source: :integration
    )
    @beta_message = ConversationThread.start_inbound!(
      workspace: @beta, contact: contacts(:bob), subject: "Beta", body: "Help",
      occurred_at: Time.current, source: :integration
    )
    @acme_thread = @acme_inbox.email_threads.create!(
      workspace: @acme, conversation: @acme_message.conversation, thread_key: "acme@example.net"
    )
  end

  test "database constraints reject cross-workspace inbox, thread, and message links" do
    assert_raises(ActiveRecord::InvalidForeignKey) do
      EmailThread.transaction(requires_new: true) do
        EmailThread.insert_all!([ {
          workspace_id: @beta.id,
          shared_email_inbox_id: @acme_inbox.id,
          conversation_id: @beta_message.conversation_id,
          thread_key: "foreign@example.net",
          created_at: Time.current,
          updated_at: Time.current
        } ])
      end
    end

    assert_raises(ActiveRecord::InvalidForeignKey) do
      InboundEmailDelivery.transaction(requires_new: true) do
        InboundEmailDelivery.insert_all!([ {
          workspace_id: @beta.id,
          shared_email_inbox_id: @acme_inbox.id,
          source_message_id: "foreign@example.net",
          content_sha256: "a" * 64,
          raw_email: "raw",
          received_at: Time.current,
          created_at: Time.current,
          updated_at: Time.current
        } ])
      end
    end

    assert_raises(ActiveRecord::InvalidForeignKey) do
      EmailMessageLink.transaction(requires_new: true) do
        EmailMessageLink.insert_all!([ {
          workspace_id: @beta.id,
          shared_email_inbox_id: @beta_inbox.id,
          email_thread_id: @acme_thread.id,
          conversation_id: @beta_message.conversation_id,
          conversation_message_id: @beta_message.id,
          message_id: "foreign-link@example.net",
          created_at: Time.current,
          updated_at: Time.current
        } ])
      end
    end
  end
end
