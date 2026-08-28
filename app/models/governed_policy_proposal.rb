class GovernedPolicyProposal < ApplicationRecord
  SCOPE_KINDS = %w[support_case account agent_profile].freeze

  belongs_to :workspace
  belongs_to :resolution_contract_family
  belongs_to :agent_profile
  belongs_to :prior_resolution_contract_version, class_name: "ResolutionContractVersion"
  belongs_to :resolution_contract_version
  belongs_to :prior_agent_profile_version, class_name: "AgentProfileVersion"
  belongs_to :agent_profile_version
  belongs_to :created_by_membership, class_name: "Membership"
  belongs_to :created_by_user, class_name: "User"
  has_many :subjects, -> { order(:id) }, class_name: "GovernedPolicySubject",
    dependent: :restrict_with_exception
  has_many :previews, -> { order(id: :desc) }, class_name: "GovernedPolicyPreview",
    dependent: :restrict_with_exception
  has_many :publications, -> { order(id: :desc) }, class_name: "GovernedPolicyPublication",
    dependent: :restrict_with_exception

  validates :scope_kind, inclusion: { in: SCOPE_KINDS }
  validates :reason, presence: true, length: { maximum: 500 }
  validate :version_chain_is_consistent
  validate :actor_is_consistent

  def readonly?
    persisted?
  end

  private
    def version_chain_is_consistent
      records = [ resolution_contract_family, agent_profile, prior_resolution_contract_version,
        resolution_contract_version, prior_agent_profile_version, agent_profile_version ].compact
      errors.add(:base, "Policy versions belong to another Workspace") if records.any? { |record| record.workspace_id != workspace_id }
      if resolution_contract_family && [ prior_resolution_contract_version, resolution_contract_version ].compact.any? do |version|
          version.resolution_contract_family_id != resolution_contract_family_id
        end
        errors.add(:resolution_contract_version, "does not belong to the contract family")
      end
      if agent_profile && [ prior_agent_profile_version, agent_profile_version ].compact.any? do |version|
          version.agent_profile_id != agent_profile_id
        end
        errors.add(:agent_profile_version, "does not belong to the profile")
      end
    end

    def actor_is_consistent
      if created_by_membership &&
          (created_by_membership.workspace_id != workspace_id || created_by_membership.user_id != created_by_user_id)
        errors.add(:created_by_membership, "does not match Workspace and user")
      end
    end
end
