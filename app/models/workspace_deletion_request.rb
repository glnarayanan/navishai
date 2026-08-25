class WorkspaceDeletionRequest < ApplicationRecord
  STATUSES = %w[pending running failed].freeze

  belongs_to :workspace
  belongs_to :requested_by, class_name: "User"

  enum :status, STATUSES.index_by(&:itself), validate: true

  validates :attempt_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :failure_code, format: { with: /\A[a-z][a-z0-9_]{0,99}\z/ }, allow_nil: true
end
