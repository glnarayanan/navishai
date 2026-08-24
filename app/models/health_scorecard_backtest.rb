class HealthScorecardBacktest < ApplicationRecord
  belongs_to :workspace
  belongs_to :health_scorecard_version
  belongs_to :membership
  belongs_to :user

  validates :source_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :sample_count, numericality: { only_integer: true, in: 0..500 }
  validates :generated_at, presence: true
  validate :results_are_bounded

  def readonly? = persisted?

  private
    def results_are_bounded
      errors.add(:results, "must be a bounded object") unless results.is_a?(Hash) && results.to_json.bytesize <= 1.megabyte
    end
end
