class PublicWebSearch < ApplicationRecord
  STATUSES = %w[searching completed failed].freeze

  belongs_to :workspace
  belongs_to :crew_task
  belongs_to :requested_by_membership, class_name: "Membership"
  belongs_to :requested_by_user, class_name: "User"
  belongs_to :usage_rate_version, optional: true
  has_many :results, -> { order(:rank) }, class_name: "PublicWebSearchResult", dependent: :restrict_with_exception
  has_one :usage_cost_snapshot, dependent: :restrict_with_exception

  enum :status, STATUSES.index_with(&:itself)

  validates :request_key, presence: true, length: { maximum: 128 }, format: { with: /\A[a-zA-Z0-9][a-zA-Z0-9._:-]*\z/ }, uniqueness: { scope: :workspace_id }
  validates :query, presence: true, length: { in: 2..500 }
  validates :status, inclusion: { in: STATUSES }
  validates :policy_decision, inclusion: { in: %w[allowed redacted] }
  validates :cost_units, numericality: {
    only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: RunnerProtocol::BIGINT_MAX
  }
  attr_readonly :requested_provider_key
  validates :requested_provider_key, format: { with: RunnerProtocol::POLICY_KEY_PATTERN }, allow_nil: true
  validates :provider_key, format: { with: RunnerProtocol::POLICY_KEY_PATTERN }, allow_nil: true
  validates :failure_code, format: { with: RunnerProtocol::POLICY_KEY_PATTERN }, allow_nil: true
  validate :assignment_is_consistent
  validate :query_fits_protocol
  validate :result_is_consistent

  private
    def assignment_is_consistent
      return if workspace.nil? || crew_task.nil? || requested_by_membership.nil? || requested_by_user.nil?

      unless crew_task.workspace_id == workspace_id && requested_by_membership.workspace_id == workspace_id &&
          requested_by_membership.user_id == requested_by_user_id
        errors.add(:workspace, "does not match the task and actor")
      end
      errors.add(:usage_rate_version, "belongs to another workspace") if usage_rate_version && usage_rate_version.workspace_id != workspace_id
    end

    def result_is_consistent
      valid = case status
      when "searching" then provider_key.nil? && failure_code.nil? && retrieved_at.nil?
      when "completed" then provider_key.present? && failure_code.nil? && retrieved_at.present?
      when "failed" then provider_key.nil? && failure_code.present? && retrieved_at.nil?
      end
      errors.add(:status, "does not match the search result") unless valid
    end

    def query_fits_protocol
      errors.add(:query, "is too long") if query.to_s.bytesize > 500
    end
end
