class ConversationMessageAttachment < ApplicationRecord
  belongs_to :workspace
  belongs_to :conversation
  belongs_to :conversation_message
  belongs_to :stored_attachment

  validate :records_match

  private
    def records_match
      records = [ conversation, conversation_message, stored_attachment ]
      errors.add(:base, "records belong to another workspace") if records.compact.any? { |record| record.workspace_id != workspace_id }
      errors.add(:conversation_message, "does not match conversation") if conversation_message && conversation_message.conversation_id != conversation_id
    end
end
