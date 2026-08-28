class IntercomBackfillReport < ApplicationRecord
  belongs_to :workspace
  belongs_to :intercom_backfill_run

  enum :status, %w[partial complete].index_by(&:itself), validate: true
  validates :report_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :generated_at, presence: true

  def reconciled?
    counts.fetch("discovered") == %w[imported matched skipped ambiguous failed pending].sum { |key| counts.fetch(key) }
  end

  def readonly? = persisted?
end
