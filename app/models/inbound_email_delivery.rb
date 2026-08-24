class InboundEmailDelivery < ApplicationRecord
  STATUSES = %w[received processed failed].freeze
  FAILURE_CODES = %w[parse_error missing_sender missing_message_id empty_body body_too_large identity_ambiguous identity_error persistence_error].freeze
  MAX_BYTES = 10.megabytes

  belongs_to :workspace
  belongs_to :shared_email_inbox
  belongs_to :conversation, optional: true
  belongs_to :conversation_message, optional: true

  enum :status, STATUSES.index_by(&:itself), validate: true

  scope :outstanding, -> { where(status: %w[received failed]) }

  validates :source_message_id, presence: true, length: { maximum: 998 }, uniqueness: { scope: :shared_email_inbox_id }
  validates :content_sha256, presence: true, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :raw_email, presence: true, length: { maximum: MAX_BYTES }
  validates :received_at, presence: true
  validates :failure_code, inclusion: { in: FAILURE_CODES }, allow_nil: true
  validate :inbox_belongs_to_workspace

  private
    def inbox_belongs_to_workspace
      errors.add(:shared_email_inbox, "belongs to another workspace") if shared_email_inbox && shared_email_inbox.workspace_id != workspace_id
    end
end
