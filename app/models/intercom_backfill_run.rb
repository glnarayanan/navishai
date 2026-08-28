class IntercomBackfillRun < ApplicationRecord
  STATUSES = %w[pending running blocked failed completed].freeze

  belongs_to :workspace
  belongs_to :intercom_connection
  belongs_to :intercom_backfill_manifest
  belongs_to :confirmed_by_membership, class_name: "Membership"
  belongs_to :confirmed_by_user, class_name: "User"
  has_many :intercom_backfill_batches, dependent: :restrict_with_exception
  has_many :intercom_backfill_exceptions, dependent: :restrict_with_exception
  has_one :intercom_backfill_report, dependent: :restrict_with_exception

  enum :status, STATUSES.index_by(&:itself), validate: true
  validates :source_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :cursor_position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :confirmed_at, presence: true
end
