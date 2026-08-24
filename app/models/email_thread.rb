class EmailThread < ApplicationRecord
  belongs_to :workspace
  belongs_to :shared_email_inbox
  belongs_to :conversation
  has_many :email_message_links, dependent: :restrict_with_exception
  has_many :email_drafts, dependent: :restrict_with_exception
  has_many :outbound_email_deliveries, dependent: :restrict_with_exception

  validates :thread_key, presence: true, length: { maximum: 998 },
    uniqueness: { scope: :shared_email_inbox_id }
  validate :records_belong_to_workspace

  def readonly?
    persisted?
  end

  private
    def records_belong_to_workspace
      errors.add(:shared_email_inbox, "belongs to another workspace") if shared_email_inbox && shared_email_inbox.workspace_id != workspace_id
      errors.add(:conversation, "belongs to another workspace") if conversation && conversation.workspace_id != workspace_id
    end
end
