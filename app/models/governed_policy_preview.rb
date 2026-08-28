class GovernedPolicyPreview < ApplicationRecord
  RESULT_KEYS = %w[changes facts old_decision proposed_decision result subject_id subject_kind].freeze

  belongs_to :workspace
  belongs_to :proposal, class_name: "GovernedPolicyProposal", foreign_key: :governed_policy_proposal_id
  belongs_to :created_by_membership, class_name: "Membership"
  belongs_to :created_by_user, class_name: "User"
  has_one :publication, class_name: "GovernedPolicyPublication", dependent: :restrict_with_exception

  validates :evidence_digest, :results_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :subject_count, numericality: { only_integer: true, in: 1..50 }
  validate :payload_is_bounded
  validate :digests_match_payloads, unless: :expired_at?
  validate :records_are_consistent

  def readonly?
    persisted?
  end

  private
    def payload_is_bounded
      unless source_snapshot.is_a?(Hash) && results.is_a?(Array) && results.size == subject_count &&
          source_snapshot.to_json.bytesize <= 512.kilobytes && results.to_json.bytesize <= 512.kilobytes
        errors.add(:base, "Preview evidence is invalid or too large")
      end
      unless results.all? { |result| result.is_a?(Hash) && result.keys.sort == RESULT_KEYS }
        errors.add(:results, "do not match the typed preview contract")
      end
    end

    def records_are_consistent
      records = [ proposal, created_by_membership ].compact
      errors.add(:base, "records belong to another Workspace") if records.any? { |record| record.workspace_id != workspace_id }
      if created_by_membership && created_by_membership.user_id != created_by_user_id
        errors.add(:created_by_membership, "does not match the user")
      end
    end

    def digests_match_payloads
      errors.add(:evidence_digest, "does not match stored evidence") unless
        evidence_digest == GovernedPolicyChange.digest(source_snapshot)
      errors.add(:results_digest, "does not match stored results") unless
        results_digest == GovernedPolicyChange.digest(results)
    end
end
