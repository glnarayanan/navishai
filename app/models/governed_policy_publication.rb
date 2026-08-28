class GovernedPolicyPublication < ApplicationRecord
  ACTIONS = %w[canary rollback].freeze

  belongs_to :workspace
  belongs_to :proposal, class_name: "GovernedPolicyProposal", foreign_key: :governed_policy_proposal_id
  belongs_to :preview, class_name: "GovernedPolicyPreview", foreign_key: :governed_policy_preview_id, optional: true
  belongs_to :supersedes_publication, class_name: "GovernedPolicyPublication", optional: true
  belongs_to :resolution_contract_version
  belongs_to :agent_profile_version
  belongs_to :created_by_membership, class_name: "Membership"
  belongs_to :created_by_user, class_name: "User"
  has_one :successor, class_name: "GovernedPolicyPublication", foreign_key: :supersedes_publication_id,
    dependent: :restrict_with_exception, inverse_of: :supersedes_publication
  has_many :crew_tasks, dependent: :restrict_with_exception
  has_many :execution_runs, dependent: :restrict_with_exception
  has_many :crew_artifacts, dependent: :restrict_with_exception

  enum :action, ACTIONS.index_by(&:itself), validate: true, suffix: true
  validates :reason, presence: true, length: { maximum: 500 }
  validate :shape_is_consistent

  delegate :subjects, :scope_kind, :agent_profile, to: :proposal

  def readonly?
    persisted?
  end

  def support_cases
    SupportCase.where(id: subjects.where(subject_kind: "support_case").select(:support_case_id))
  end

  def accounts
    Account.where(id: subjects.where(subject_kind: "account").select(:account_id))
  end

  private
    def shape_is_consistent
      expected = canary_action? ? preview.present? : preview.nil? && supersedes_publication.present?
      errors.add(:action, "does not match publication evidence") unless expected
      records = [ proposal, preview, supersedes_publication, resolution_contract_version,
        agent_profile_version, created_by_membership ].compact
      errors.add(:base, "records belong to another Workspace") if records.any? { |record| record.workspace_id != workspace_id }
      if created_by_membership && created_by_membership.user_id != created_by_user_id
        errors.add(:created_by_membership, "does not match the user")
      end
      if canary_action? && proposal
        errors.add(:preview, "does not belong to the proposal") if preview&.proposal != proposal
        errors.add(:resolution_contract_version, "does not match the proposal candidate") unless
          resolution_contract_version == proposal.resolution_contract_version
        errors.add(:agent_profile_version, "does not match the proposal candidate") unless
          agent_profile_version == proposal.agent_profile_version
        if supersedes_publication && !same_scope_chain?(supersedes_publication.proposal, proposal)
          errors.add(:supersedes_publication, "does not belong to the exact canary scope")
        end
      elsif rollback_action? && proposal
        errors.add(:resolution_contract_version, "does not match the proposal prior version") unless
          resolution_contract_version == proposal.prior_resolution_contract_version
        errors.add(:agent_profile_version, "does not match the proposal prior version") unless
          agent_profile_version == proposal.prior_agent_profile_version
        errors.add(:supersedes_publication, "does not belong to the proposal") unless
          supersedes_publication&.proposal == proposal
      end
    end

    def same_scope_chain?(left, right)
      return false unless left.scope_kind == right.scope_kind &&
        left.resolution_contract_family_id == right.resolution_contract_family_id &&
        left.agent_profile_id == right.agent_profile_id

      signature = ->(policy) do
        policy.subjects.map do |subject|
          [ subject.subject_kind, subject.support_case_id, subject.account_id, subject.agent_profile_id ]
        end.sort
      end
      signature.call(left) == signature.call(right)
    end
end
