class WorkspaceContentExpiryRun < ApplicationRecord
  STATUSES = %w[pending running completed failed].freeze

  belongs_to :workspace

  enum :status, STATUSES.index_by(&:itself), validate: true

  validates :cutoff_at, presence: true
  validates :expired_record_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :failure_code, format: { with: /\A[a-z][a-z0-9_]{0,99}\z/ }, allow_nil: true
end
