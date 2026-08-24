class InboundEmailDelivery < ApplicationRecord
  STATUSES = %w[received processed failed].freeze
  FAILURE_CODES = %w[parse_error missing_sender missing_message_id message_id_conflict empty_body body_too_large identity_ambiguous identity_error persistence_error].freeze
  RETRYABLE_FAILURE_CODES = %w[identity_ambiguous identity_error persistence_error].freeze
  MAX_BYTES = 10.megabytes

  belongs_to :workspace
  belongs_to :shared_email_inbox
  belongs_to :conversation, optional: true
  belongs_to :conversation_message, optional: true

  enum :status, STATUSES.index_by(&:itself), validate: true

  scope :outstanding, -> {
    where(status: :received).or(where(status: :failed, failure_code: RETRYABLE_FAILURE_CODES))
      .where(attempt_count: ...SharedEmailIntake::MAX_RECONCILIATION_ATTEMPTS)
  }

  validates :source_message_id, presence: true, length: { maximum: 998 },
    uniqueness: { scope: %i[shared_email_inbox_id content_sha256] }
  validates :content_sha256, presence: true, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :raw_email, presence: true, length: { maximum: MAX_BYTES }
  validates :received_at, presence: true
  validates :attempt_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :failure_code, inclusion: { in: FAILURE_CODES }, allow_nil: true
  validate :inbox_belongs_to_workspace

  private
    def inbox_belongs_to_workspace
      errors.add(:shared_email_inbox, "belongs to another workspace") if shared_email_inbox && shared_email_inbox.workspace_id != workspace_id
    end
end
