class EmailDraft < ApplicationRecord
  STATUSES = %w[ready sending sent].freeze
  MAX_BODY_BYTES = 1.megabyte

  belongs_to :workspace
  belongs_to :support_case
  belongs_to :email_thread
  belongs_to :conversation
  belongs_to :updated_by, class_name: "User"
  has_many :outbound_email_deliveries, dependent: :restrict_with_exception
  has_many :email_draft_attachments, dependent: :destroy
  has_many :stored_attachments, through: :email_draft_attachments

  enum :status, STATUSES.index_by(&:itself), validate: true

  validates :body, presence: true
  validate :body_size
  validate :records_match

  private
    def body_size
      errors.add(:body, "is too large") if body.to_s.bytesize > MAX_BODY_BYTES
    end

    def records_match
      records = [ support_case, email_thread, conversation ]
      if records.all?(&:present?) && [ support_case.conversation_id, email_thread.conversation_id ].any? { |id| id != conversation_id }
        errors.add(:email_thread, "does not match case")
      end
      errors.add(:base, "records belong to another workspace") if records.compact.any? { |record| record.workspace_id != workspace_id }
    end
end
