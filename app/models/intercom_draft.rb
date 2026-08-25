class IntercomDraft < ApplicationRecord
  STATUSES = %w[ready sending sent].freeze
  MAX_BODY_BYTES = 1.megabyte

  belongs_to :workspace
  belongs_to :support_case
  belongs_to :intercom_conversation_link
  belongs_to :conversation
  belongs_to :updated_by, class_name: "User"
  has_many :intercom_outbound_deliveries, dependent: :restrict_with_exception

  enum :status, STATUSES.index_by(&:itself), validate: true
  validates :body, presence: true
  validate :body_size
  validate :records_match

  private
    def body_size
      errors.add(:body, "is too large") if body.to_s.bytesize > MAX_BODY_BYTES
    end

    def records_match
      records = [ support_case, intercom_conversation_link, conversation ]
      errors.add(:base, "records belong to another workspace") if records.compact.any? { |record| record.workspace_id != workspace_id }
      errors.add(:conversation, "does not match case") if support_case && support_case.conversation_id != conversation_id
      errors.add(:conversation, "does not match Intercom link") if intercom_conversation_link && intercom_conversation_link.conversation_id != conversation_id
    end
end
