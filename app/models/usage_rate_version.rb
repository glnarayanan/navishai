class UsageRateVersion < ApplicationRecord
  MAX_RATE_MICROS = 1_000_000_000_000

  belongs_to :workspace
  belongs_to :usage_rate_setting
  belongs_to :created_by_membership, class_name: "Membership"
  belongs_to :created_by_user, class_name: "User"
  has_many :execution_runs, dependent: :restrict_with_exception
  has_many :public_web_searches, dependent: :restrict_with_exception
  has_many :usage_cost_snapshots, foreign_key: :applied_usage_rate_version_id,
    dependent: :restrict_with_exception, inverse_of: :applied_usage_rate_version

  validates :version_number, numericality: { only_integer: true, greater_than: 0 }
  validates :currency, format: { with: /\A[A-Z]{3}\z/ }
  validates :source_name, presence: true, length: { maximum: 100 }
  validates :published_at, presence: true
  validates :input_rate_micros_per_million, :output_rate_micros_per_million,
    :search_rate_micros_per_million,
    numericality: { only_integer: true, in: 0..MAX_RATE_MICROS }, allow_nil: true
  validate :at_least_one_rate
  validate :records_share_workspace

  def readonly? = persisted?

  private
    def at_least_one_rate
      rates = [ input_rate_micros_per_million, output_rate_micros_per_million,
        search_rate_micros_per_million ]
      errors.add(:base, "Set at least one rate.") if rates.all?(&:nil?)
    end

    def records_share_workspace
      records = [ usage_rate_setting, created_by_membership ].compact
      errors.add(:base, "records belong to another Workspace") if records.any? { |record| record.workspace_id != workspace_id }
      if created_by_membership && created_by_user != created_by_membership.user
        errors.add(:created_by_user, "does not match membership")
      end
    end
end
