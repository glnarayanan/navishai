class MemoryCorrectionProposal < ApplicationRecord
  STATUSES = %w[proposed accepted rejected].freeze
  RETENTION_POLICIES = %w[indefinite time_bound].freeze

  belongs_to :workspace
  belongs_to :memory_record
  belongs_to :proposed_by_membership, class_name: "Membership"
  belongs_to :proposed_by_user, class_name: "User"
  belongs_to :reviewed_by_membership, class_name: "Membership", optional: true
  belongs_to :reviewed_by_user, class_name: "User", optional: true
  belongs_to :published_memory_record, class_name: "MemoryRecord", optional: true

  enum :status, STATUSES.index_by(&:itself), validate: true
  enum :retention_policy, RETENTION_POLICIES.index_by(&:itself), validate: true, prefix: true

  validates :content, presence: true, length: { maximum: 32_768 }
  validates :content_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :confidence, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
  validate :retention_is_valid
  validate :records_share_workspace

  before_validation :set_content_digest

  private
    def set_content_digest
      self.content_digest = Digest::SHA256.hexdigest(content.to_s.b)
    end

    def retention_is_valid
      if retention_policy_time_bound?
        errors.add(:retention_until, "must be in the future") unless retention_until&.future?
      elsif retention_until
        errors.add(:retention_until, "must be blank for indefinite retention")
      end
    end

    def records_share_workspace
      records = [ memory_record, proposed_by_membership, reviewed_by_membership, published_memory_record ].compact
      errors.add(:base, "records belong to another workspace") if records.any? { |record| record.workspace_id != workspace_id }
      errors.add(:proposed_by_user, "does not match membership") if proposed_by_membership&.user_id != proposed_by_user_id
      if reviewed_by_membership && reviewed_by_membership.user_id != reviewed_by_user_id
        errors.add(:reviewed_by_user, "does not match membership")
      end
    end
end
