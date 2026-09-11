class OperationalCheck < ApplicationRecord
  CHECK_KINDS = %w[archive_verification attachment_scanner backup_verification restore_rehearsal upgrade_preflight].freeze
  RESULTS = %w[passed failed unavailable].freeze
  RESULT_CODE_FORMAT = /\A[a-z][a-z0-9_]{0,99}\z/
  SHA256_FORMAT = /\A[0-9a-f]{64}\z/
  COMMIT_FORMAT = /\A[0-9a-f]{40}\z/

  belongs_to :workspace
  belongs_to :recorded_by_membership, class_name: "Membership", optional: true
  belongs_to :recorded_by_user, class_name: "User", optional: true

  validates :check_kind, inclusion: { in: CHECK_KINDS }
  validates :result, inclusion: { in: RESULTS }
  validates :result_code, presence: true, format: { with: RESULT_CODE_FORMAT }
  validates :evidence_digest, presence: true, format: { with: SHA256_FORMAT }
  validates :source_commit, presence: true, format: { with: COMMIT_FORMAT }
  validates :archive_format, length: { maximum: 100 }, allow_nil: true
  validates :table_count, :record_count, :attachment_count, :memory_count,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validates :checked_at, presence: true
  validate :actor_is_complete

  scope :latest_first, -> { order(checked_at: :desc, id: :desc) }

  def self.record!(workspace:, check_kind:, result:, result_code:, evidence_digest:, source_commit:,
    checked_at: Time.current, membership: nil, archive_format: nil, counts: {})
    transaction do
      actor = workspace.memberships.lock.find(membership.id) if membership
      raise Current::RoleAccessDenied if actor && !actor.can_manage_work?

      create!(
        workspace:, check_kind:, result:, result_code:, evidence_digest:, source_commit:, checked_at:,
        archive_format:, recorded_by_membership: actor, recorded_by_user: actor&.user,
        table_count: counts[:table], record_count: counts[:record],
        attachment_count: counts[:attachment], memory_count: counts[:memory]
      ).tap do |check|
        AuditEvent.record!(
          action: "operations.check_recorded", source: actor ? :web : :system,
          workspace:, actor: actor&.user, actor_kind: actor ? nil : :system, subject: check,
          metadata: { check_kind: check.check_kind, result: check.result }, occurred_at: checked_at
        )
      end
    end
  end

  def readonly?
    persisted?
  end

  private
    def actor_is_complete
      both_present = recorded_by_membership && recorded_by_user
      both_absent = recorded_by_membership.nil? && recorded_by_user.nil?
      errors.add(:recorded_by_membership, "must match the recorded user") unless
        both_absent || (both_present && recorded_by_membership.workspace_id == workspace_id &&
          recorded_by_membership.user_id == recorded_by_user_id)
    end
end
