class CrewTask < ApplicationRecord
  STATUSES = %w[pending ready in_progress blocked review_requested completed failed canceled].freeze

  attribute :task_key, default: -> { SecureRandom.uuid }

  belongs_to :workspace
  belongs_to :support_case, optional: true
  belongs_to :account, optional: true
  belongs_to :crew_template
  belongs_to :assigned_agent_profile, class_name: "AgentProfile"
  belongs_to :assigned_agent_profile_version, class_name: "AgentProfileVersion"
  belongs_to :governed_policy_publication, optional: true
  belongs_to :resolution_contract_version, optional: true
  belongs_to :owner_membership, class_name: "Membership"
  belongs_to :owner_user, class_name: "User"
  belongs_to :current_event, class_name: "CrewTaskEvent", optional: true
  has_many :events, -> { order(:sequence_number) }, class_name: "CrewTaskEvent", dependent: :restrict_with_exception
  has_many :dependency_links, class_name: "CrewTaskDependency", dependent: :restrict_with_exception
  has_many :dependencies, through: :dependency_links, source: :depends_on_task
  has_many :execution_runs, dependent: :restrict_with_exception
  has_many :public_web_searches, dependent: :restrict_with_exception
  has_many :artifacts, -> { order(:artifact_kind, :version_number) },
    class_name: "CrewArtifact", dependent: :restrict_with_exception

  enum :status, STATUSES.index_by(&:itself), validate: true

  validates :task_key, presence: true, uniqueness: true
  validates :title, presence: true, length: { maximum: 200 }
  validates :input_context, :expected_output, presence: true
  validates :scope_kind, inclusion: { in: %w[support_case account] }
  validate :scope_is_consistent
  validate :assignment_is_consistent
  validate :owner_is_consistent
  validate :content_fits

  scope :active, -> { where.not(status: %w[completed canceled]) }

  def scope_record
    support_case || account
  end

  private
    def scope_is_consistent
      valid = scope_kind == "support_case" ? support_case.present? && account.nil? : account.present? && support_case.nil?
      errors.add(:scope_kind, "does not match its record") unless valid
    end

    def assignment_is_consistent
      return if assigned_agent_profile.nil? || assigned_agent_profile_version.nil? || crew_template.nil?

      unless assigned_agent_profile.workspace_id == workspace_id &&
          assigned_agent_profile.crew_template_id == crew_template_id &&
          assigned_agent_profile_version.agent_profile_id == assigned_agent_profile_id
        errors.add(:assigned_agent_profile, "does not belong to this crew and version")
      end
      if governed_policy_publication && governed_policy_publication.workspace_id != workspace_id
        errors.add(:governed_policy_publication, "belongs to another Workspace")
      end
      if governed_policy_publication &&
          (governed_policy_publication.resolution_contract_version_id != resolution_contract_version_id ||
          governed_policy_publication.agent_profile_version_id != assigned_agent_profile_version_id)
        errors.add(:governed_policy_publication, "does not match the frozen contract and profile")
      end
      if resolution_contract_version && resolution_contract_version.workspace_id != workspace_id
        errors.add(:resolution_contract_version, "belongs to another Workspace")
      end
    end

    def owner_is_consistent
      return if owner_membership.nil? || owner_user.nil?

      unless owner_membership.workspace_id == workspace_id && owner_membership.user_id == owner_user_id
        errors.add(:owner_membership, "does not match workspace and user")
      end
    end

    def content_fits
      errors.add(:title, "must be 200 bytes or less") if title.to_s.bytesize > 200
      errors.add(:input_context, "must be 8,000 bytes or less") if input_context.to_s.bytesize > 8_000
      errors.add(:expected_output, "must be 8,000 bytes or less") if expected_output.to_s.bytesize > 8_000
    end
end
