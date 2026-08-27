class UsageCostSnapshot < ApplicationRecord
  STATUSES = %w[complete partial unavailable not_reported].freeze
  SOURCES = %w[configured_rate adapter_reported].freeze

  belongs_to :workspace
  belongs_to :execution_run, optional: true
  belongs_to :public_web_search, optional: true
  belongs_to :applied_usage_rate_version, class_name: "UsageRateVersion", optional: true

  enum :status, STATUSES.index_by(&:itself), validate: true
  enum :source, SOURCES.index_by(&:itself), validate: { allow_nil: true }

  validates :captured_at, presence: true
  validates :currency, format: { with: /\A[A-Z]{3}\z/ }, allow_nil: true
  validates :amount_micros, :observed_input_units, :observed_output_units, :observed_search_units,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validate :shape_is_consistent

  def readonly? = persisted?

  private
    def shape_is_consistent
      subjects = [ execution_run, public_web_search ].compact
      errors.add(:base, "must have one ledger subject") unless subjects.one?
      records = subjects + [ applied_usage_rate_version ].compact
      errors.add(:base, "records belong to another Workspace") if records.any? { |record| record.workspace_id != workspace_id }
      money = complete? || partial?
      errors.add(:amount_micros, "does not match status") if money != amount_micros.present?
      errors.add(:source, "does not match status") if money != source.present?
      errors.add(:currency, "does not match status") if money != currency.present?
      if configured_rate? && applied_usage_rate_version.nil?
        errors.add(:applied_usage_rate_version, "is required for a configured estimate")
      end
    end
end
