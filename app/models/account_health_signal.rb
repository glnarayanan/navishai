class AccountHealthSignal < ApplicationRecord
  EVIDENCE_KINDS = %w[
    account_health_input support_case case_sla case_note conversation_message
    support_case_status_change tag crew_artifact
  ].freeze

  belongs_to :workspace
  belongs_to :account_health_assessment

  validates :signal_key, :value_kind, :source_kind, :source_locator, :range_ends_at, presence: true
  validates :weight, numericality: { only_integer: true, in: 0..100 }
  validates :risk_points, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :evidence_omitted_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :evidence_is_bounded

  def readonly? = persisted?

  def value
    value_kind == "date" ? date_value : numeric_value
  end

  def citation_uri
    "health://assessments/#{account_health_assessment_id}/signals/#{signal_key}"
  end

  private
    def evidence_is_bounded
      valid = evidence_refs.is_a?(Array) && evidence_refs.size <= 100 && evidence_refs.all? do |reference|
        reference.is_a?(Hash) && reference.keys.sort == %w[id kind] &&
          reference["kind"].in?(EVIDENCE_KINDS) && reference["id"].is_a?(Integer)
      end
      errors.add(:evidence_refs, "must contain at most 100 typed record references") unless valid
    end
end
