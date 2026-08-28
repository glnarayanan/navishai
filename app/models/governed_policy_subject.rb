class GovernedPolicySubject < ApplicationRecord
  belongs_to :workspace
  belongs_to :proposal, class_name: "GovernedPolicyProposal", foreign_key: :governed_policy_proposal_id
  belongs_to :support_case, optional: true
  belongs_to :account, optional: true
  belongs_to :agent_profile, optional: true

  validates :subject_kind, inclusion: { in: GovernedPolicyProposal::SCOPE_KINDS }
  validates :support_case_id, uniqueness: { scope: :governed_policy_proposal_id }, allow_nil: true
  validates :account_id, uniqueness: { scope: :governed_policy_proposal_id }, allow_nil: true
  validates :agent_profile_id, uniqueness: { scope: :governed_policy_proposal_id }, allow_nil: true
  validate :shape_is_consistent

  def readonly?
    persisted?
  end

  def subject
    support_case || account || agent_profile
  end

  private
    def shape_is_consistent
      expected = { "support_case" => support_case, "account" => account, "agent_profile" => agent_profile }
      selected = [ support_case, account, agent_profile ].compact
      errors.add(:subject_kind, "does not match its record") unless selected.one? && expected[subject_kind].present?
      errors.add(:base, "records belong to another Workspace") if
        [ proposal, *selected ].compact.any? { |record| record.workspace_id != workspace_id }
    end
end
