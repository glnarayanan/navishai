class CustomerSuccessIntervention < ApplicationRecord
  STATUSES = %w[proposed approved completed abandoned reviewed].freeze
  MAX_SUPPORTING_EVIDENCE = 20

  belongs_to :workspace
  belongs_to :account
  belongs_to :account_health_assessment
  belongs_to :account_risk_investigation, optional: true
  belongs_to :proposing_crew_artifact, class_name: "CrewArtifact"
  belongs_to :accountable_membership, class_name: "Membership"
  belongs_to :proposed_by_membership, class_name: "Membership"
  belongs_to :approved_by_membership, class_name: "Membership", optional: true
  belongs_to :completed_by_membership, class_name: "Membership", optional: true
  belongs_to :abandoned_by_membership, class_name: "Membership", optional: true
  has_one :outcome_review, class_name: "CustomerSuccessInterventionOutcomeReview",
    dependent: :restrict_with_exception
  has_many :due_notices, class_name: "CustomerSuccessInterventionDueNotice",
    dependent: :restrict_with_exception

  enum :status, STATUSES.index_by(&:itself), validate: true

  validates :expected_observable_change, presence: true, length: { maximum: 2_000 }
  validates :reason, presence: true, length: { maximum: 1_000 }
  validates :abandonment_reason, presence: true, length: { maximum: 1_000 }, if: :abandoned?
  validates :target_on, :proposed_at, presence: true
  validate :supporting_evidence_is_bounded
  validate :target_follows_proposal
  validate :records_share_scope

  def overdue?(on: Date.current)
    target_on < on && (proposed? || approved?)
  end

  private
    def supporting_evidence_is_bounded
      valid = supporting_evidence.is_a?(Array) && supporting_evidence.size.in?(1..MAX_SUPPORTING_EVIDENCE) &&
        supporting_evidence.all? do |evidence|
          evidence.is_a?(Hash) && evidence.keys.sort == %w[kind label locator] &&
            evidence.values.all? { |value| value.is_a?(String) && value.present? }
        end
      errors.add(:supporting_evidence, "must contain 1 to 20 typed citations") unless valid
    end

    def target_follows_proposal
      return unless target_on && proposed_at

      errors.add(:target_on, "cannot be before the proposal date") if target_on < proposed_at.to_date
    end

    def records_share_scope
      scoped_records = [ account, account_health_assessment, account_risk_investigation,
        proposing_crew_artifact, accountable_membership, proposed_by_membership,
        approved_by_membership, completed_by_membership, abandoned_by_membership ].compact
      errors.add(:base, "records belong to another Workspace") if
        scoped_records.any? { |record| record.workspace_id != workspace_id }
      errors.add(:account_health_assessment, "belongs to another Account") if
        account_health_assessment && account_health_assessment.account_id != account_id
      errors.add(:account_risk_investigation, "belongs to another Account") if
        account_risk_investigation && account_risk_investigation.account_id != account_id
      errors.add(:account_risk_investigation, "does not match the originating assessment") if
        account_risk_investigation && account_health_assessment &&
          account_risk_investigation.account_health_assessment_id != account_health_assessment_id
      errors.add(:proposing_crew_artifact, "belongs to another Account") if
        proposing_crew_artifact&.crew_task&.account_id != account_id
    end
end
