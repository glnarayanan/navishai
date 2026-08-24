class MemoryTombstone < ApplicationRecord
  INDEX_STATUSES = %w[pending removing removed failed unknown].freeze

  belongs_to :workspace
  belongs_to :memory_record
  belongs_to :deleted_by_membership, class_name: "Membership"
  belongs_to :deleted_by_user, class_name: "User"

  enum :index_status, INDEX_STATUSES.index_by(&:itself), validate: true, prefix: true

  validates :reason, presence: true, length: { maximum: 500 }
  validates :attempt_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :failure_code, format: { with: /\A[a-z][a-z0-9_]{0,99}\z/ }, allow_nil: true
  validate :records_share_workspace

  private
    def records_share_workspace
      records = [ memory_record, deleted_by_membership ].compact
      errors.add(:base, "records belong to another workspace") if records.any? { |record| record.workspace_id != workspace_id }
      if deleted_by_membership && deleted_by_membership.user_id != deleted_by_user_id
        errors.add(:deleted_by_user, "does not match membership")
      end
    end
end
