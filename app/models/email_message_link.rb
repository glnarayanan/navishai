class EmailMessageLink < ApplicationRecord
  belongs_to :workspace
  belongs_to :shared_email_inbox
  belongs_to :email_thread
  belongs_to :conversation
  belongs_to :conversation_message

  validates :message_id, presence: true, length: { maximum: 998 },
    uniqueness: { scope: :shared_email_inbox_id }
  validate :records_match

  def readonly?
    persisted?
  end

  private
    def records_match
      errors.add(:shared_email_inbox, "does not match thread") if email_thread && shared_email_inbox != email_thread.shared_email_inbox
      errors.add(:conversation, "does not match thread") if email_thread && conversation != email_thread.conversation
      errors.add(:conversation_message, "does not match conversation") if conversation_message && conversation != conversation_message.conversation
      errors.add(:base, "records belong to another workspace") if [ shared_email_inbox, email_thread, conversation, conversation_message ].compact.any? { |record| record.workspace_id != workspace_id }
    end
end
