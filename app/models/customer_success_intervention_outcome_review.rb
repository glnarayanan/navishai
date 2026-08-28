class CustomerSuccessInterventionOutcomeReview < ApplicationRecord
  MAX_FACTS = 50

  belongs_to :workspace
  belongs_to :customer_success_intervention
  belongs_to :before_account_health_assessment, class_name: "AccountHealthAssessment"
  belongs_to :after_account_health_assessment, class_name: "AccountHealthAssessment"
  belongs_to :reviewed_by_membership, class_name: "Membership"

  validates :uncertainty, :observed_association, presence: true, length: { maximum: 2_000 }
  validates :reviewed_at, presence: true
  validate :snapshots_are_bounded
  validate :records_share_scope

  def readonly? = persisted?

  def retention_expired?
    before_snapshot == { "retention" => "expired" }
  end

  private
    def snapshots_are_bounded
      snapshots_valid = [ before_snapshot, after_snapshot ].all? do |snapshot|
        snapshot.is_a?(Hash) && snapshot.to_json.bytesize <= 128.kilobytes
      end
      facts_valid = [ changed_facts, unchanged_facts ].all? do |facts|
        facts.is_a?(Array) && facts.size <= MAX_FACTS
      end
      errors.add(:base, "outcome snapshots are invalid") unless snapshots_valid && facts_valid
    end

    def records_share_scope
      intervention = customer_success_intervention
      records = [ intervention, before_account_health_assessment,
        after_account_health_assessment, reviewed_by_membership ].compact
      errors.add(:base, "records belong to another Workspace") if
        records.any? { |record| record.workspace_id != workspace_id }
      return unless intervention

      [ before_account_health_assessment, after_account_health_assessment ].compact.each do |assessment|
        errors.add(:base, "assessments belong to another Account") if assessment.account_id != intervention.account_id
      end
    end
end
