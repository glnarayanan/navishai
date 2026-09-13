class HealthScorecardProposal < ApplicationRecord
  STATUSES = %w[valid invalid unsupported incomplete].freeze

  belongs_to :workspace
  belongs_to :health_scorecard
  belongs_to :crew_task
  belongs_to :execution_run
  belongs_to :created_by_membership, class_name: "Membership"
  belongs_to :created_by_user, class_name: "User"
  has_one :accepted_version, class_name: "HealthScorecardVersion", foreign_key: :source_proposal_id,
    inverse_of: :source_proposal, dependent: :restrict_with_exception

  enum :validation_status, STATUSES.index_by(&:itself), validate: true, suffix: :status

  validates :prompt, length: { in: 1..2_000 }
  validates :explanation, length: { in: 1..8_000 }
  validates :payload_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :execution_run_id, uniqueness: true
  validate :collections_are_bounded
  validate :definition_matches_status
  validate :records_are_consistent

  def readonly? = persisted?

  def accepted? = accepted_version.present?

  def acceptable? = valid_status? && !accepted?

  private
    def collections_are_bounded
      {
        assumptions: assumptions, unsupported_requests: unsupported_requests, missing_evidence: missing_evidence
      }.each do |name, value|
        unless value.is_a?(Array) && value.size <= 20 && value.all? { |entry| entry.is_a?(String) && entry.bytesize.in?(1..1_000) }
          errors.add(name, "must be at most 20 plain-text entries")
        end
      end
    end

    def definition_matches_status
      if valid_status?
        errors.add(:proposed_definition, "must be present") if proposed_definition.blank?
      elsif proposed_definition.present?
        errors.add(:proposed_definition, "must be empty unless the proposal is valid")
      end
    end

    def records_are_consistent
      records = [ health_scorecard, crew_task, execution_run, created_by_membership ].compact
      errors.add(:base, "records belong to another workspace") if records.any? { |record| record.workspace_id != workspace_id }
      if crew_task && (crew_task.health_scorecard_id != health_scorecard_id || crew_task.scope_kind != "health_scorecard")
        errors.add(:crew_task, "does not match this scorecard")
      end
      if execution_run && crew_task && execution_run.crew_task_id != crew_task_id
        errors.add(:execution_run, "does not belong to this task")
      end
      if created_by_membership && created_by_user && created_by_membership.user_id != created_by_user_id
        errors.add(:created_by_membership, "does not match the proposing user")
      end
    end
end
