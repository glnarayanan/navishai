require "test_helper"

class ConversationMessageTest < ActiveSupport::TestCase
  test "requires exactly the author that matches its author kind" do
    conversation = start_conversation
    message = ConversationMessage.new(
      workspace: conversation.workspace,
      conversation: conversation,
      direction: :inbound,
      author_kind: :contact,
      author_user: users(:owner),
      body: "Hello",
      occurred_at: Time.current
    )

    assert_not message.valid?
    assert_includes message.errors[:author_contact], "does not match author kind"
    assert_includes message.errors[:author_user], "does not match author kind"
  end

  test "persisted messages are immutable" do
    conversation = start_conversation
    message = ConversationThread.append_inbound!(
      workspace: conversation.workspace, conversation: conversation, author: conversation.contact,
      body: "Original", occurred_at: Time.current, source: :integration
    )

    assert_raises(ActiveRecord::ReadOnlyRecord) { message.update!(body: "Changed") }
    assert_raises(ActiveRecord::ReadOnlyRecord) { message.destroy! }
  end

  test "database rejects a reply from another conversation" do
    first = start_conversation
    second = start_conversation
    original = ConversationThread.append_inbound!(
      workspace: first.workspace, conversation: first, author: first.contact,
      body: "First", occurred_at: Time.current, source: :integration
    )

    assert_raises(ActiveRecord::StatementInvalid) do
      ConversationMessage.transaction(requires_new: true) do
        ConversationMessage.create!(
          workspace: second.workspace,
          conversation: second,
          direction: :inbound,
          author_kind: :contact,
          author_contact: second.contact,
          in_reply_to: original,
          body: "Wrong thread",
          occurred_at: Time.current
        )
      end
    end
  end

  private
    def start_conversation
      ConversationThread.start!(
        workspace: workspaces(:acme_support), contact: contacts(:alice),
        membership: memberships(:owner_support), occurred_at: Time.current
      )
    end
end
