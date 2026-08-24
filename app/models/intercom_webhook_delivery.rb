class IntercomWebhookDelivery < ApplicationRecord
  MAX_BYTES = 1.megabyte
  STATUSES = %w[received processed failed].freeze
  RETRYABLE_FAILURES = %w[identity_ambiguous remote_unavailable persistence_error].freeze
  MAX_ATTEMPTS = 5
  FAILURE_CODES = %w[invalid_payload unsupported_topic identity_ambiguous remote_unavailable persistence_error].freeze

  belongs_to :workspace
  belongs_to :intercom_connection

  enum :status, STATUSES.index_by(&:itself), validate: true
  validates :notification_id, presence: true, uniqueness: { scope: :intercom_connection_id }
  validates :topic, :content_sha256, :raw_payload, :received_at, presence: true

  scope :retryable, -> {
    where(status: :received).or(where(status: :failed, failure_code: RETRYABLE_FAILURES).where("attempt_count < ?", MAX_ATTEMPTS))
  }
end
