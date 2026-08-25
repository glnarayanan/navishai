class AccountHealthSignal < ApplicationRecord
  belongs_to :workspace
  belongs_to :account_health_assessment

  validates :signal_key, :value_kind, :source_kind, :source_locator, :range_ends_at, presence: true
  validates :weight, numericality: { only_integer: true, in: 0..100 }
  validates :risk_points, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  def readonly? = persisted?

  def value
    value_kind == "date" ? date_value : numeric_value
  end

  def citation_uri
    "health://assessments/#{account_health_assessment_id}/signals/#{signal_key}"
  end
end
