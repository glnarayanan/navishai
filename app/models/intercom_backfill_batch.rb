class IntercomBackfillBatch < ApplicationRecord
  STATUSES = %w[running completed blocked failed].freeze

  belongs_to :workspace
  belongs_to :intercom_backfill_run

  enum :status, STATUSES.index_by(&:itself), validate: true
  validates :start_position, :end_position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :attempt_number, numericality: { only_integer: true, greater_than: 0 }
  validates :source_digest, format: { with: /\A[0-9a-f]{64}\z/ }
end
