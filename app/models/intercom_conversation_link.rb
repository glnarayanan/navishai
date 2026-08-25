class IntercomConversationLink < ApplicationRecord
  belongs_to :workspace
  belongs_to :intercom_connection
  belongs_to :conversation
  belongs_to :support_case
  has_many :intercom_part_links, dependent: :restrict_with_exception
  has_many :intercom_sync_operations, dependent: :restrict_with_exception

  validates :remote_conversation_id, presence: true, uniqueness: { scope: :intercom_connection_id }
  validates :remote_state, :source_digest, :remote_updated_at, :synced_at, presence: true
  validate :records_stay_in_workspace

  private
    def records_stay_in_workspace
      errors.add(:conversation, "must belong to the workspace") if conversation && conversation.workspace_id != workspace_id
      errors.add(:support_case, "must belong to the conversation") if support_case && support_case.conversation_id != conversation_id
      errors.add(:intercom_connection, "must belong to the workspace") if intercom_connection && intercom_connection.workspace_id != workspace_id
    end
end
