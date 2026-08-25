class Membership < ApplicationRecord
  ROLES = %w[owner admin manager member viewer].freeze

  belongs_to :workspace
  belongs_to :user
  has_many :assigned_support_cases, class_name: "SupportCase", foreign_key: :assigned_membership_id, dependent: :restrict_with_exception
  has_many :owned_crew_tasks, class_name: "CrewTask", foreign_key: :owner_membership_id,
    dependent: :restrict_with_exception
  has_many :proposed_memory_corrections, class_name: "MemoryCorrectionProposal",
    foreign_key: :proposed_by_membership_id, dependent: :restrict_with_exception
  has_many :intercom_sync_operations, dependent: :restrict_with_exception

  enum :role, ROLES.index_by(&:itself), validate: true

  scope :owners, -> { where(role: :owner) }

  validates :user_id, uniqueness: { scope: :workspace_id }

  before_destroy :retain_an_owner
  before_update :retain_an_owner_after_role_change, if: -> { role_changed? && role_was == "owner" }

  def can_write?
    !viewer?
  end

  def can_manage_work?
    owner? || admin? || manager?
  end

  def can_inspect_memory?
    !viewer?
  end

  def can_configure_integrations?
    owner? || admin?
  end

  def can_configure_agents?
    owner? || admin?
  end

  def can_invite_role?(invited_role)
    return true if owner? && ROLES.include?(invited_role.to_s)

    admin? && %w[manager member viewer].include?(invited_role.to_s)
  end

  def can_manage?(other_membership)
    return false unless workspace_id == other_membership.workspace_id
    return true if owner?

    admin? && %w[manager member viewer].include?(other_membership.role) && self != other_membership
  end

  private
    def retain_an_owner
      prevent_last_owner_change if owner?
    end

    def retain_an_owner_after_role_change
      prevent_last_owner_change
    end

    def prevent_last_owner_change
      lock_owner_changes
      return if workspace.memberships.owners.where.not(id: id).exists?

      errors.add(:base, "Workspace must retain at least one Owner")
      throw :abort
    end

    def lock_owner_changes
      lock_name = self.class.connection.quote("navishai-workspace-owners-#{workspace_id}")
      self.class.connection.execute("SELECT pg_advisory_xact_lock(hashtext(#{lock_name}))")
    end
end
