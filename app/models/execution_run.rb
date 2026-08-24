class ExecutionRun < ApplicationRecord
  STATUSES = %w[admitting admitted running completed failed timed_out canceled policy_denied].freeze
  TERMINAL_STATUSES = %w[completed failed timed_out canceled policy_denied].freeze

  attribute :run_key, default: -> { SecureRandom.uuid }

  belongs_to :workspace
  belongs_to :crew_task
  belongs_to :agent_profile
  belongs_to :agent_profile_version
  belongs_to :current_event, class_name: "ExecutionEvent", optional: true
  belongs_to :input_artifact, class_name: "CrewArtifact", optional: true
  has_many :events, -> { order(:sequence_number) }, class_name: "ExecutionEvent", dependent: :restrict_with_exception
  has_one :crew_artifact, dependent: :restrict_with_exception

  enum :status, STATUSES.index_by(&:itself), validate: true

  validates :run_key, presence: true, uniqueness: true
  validates :request_key, presence: true, length: { maximum: 128 }, uniqueness: { scope: :workspace_id }
  validates :attempt_number, numericality: { only_integer: true, greater_than: 0 }
  validates :current_sequence, :admission_attempt_count, :input_units, :output_units,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :runtime_profile_key, inclusion: { in: AgentPolicy::RUNTIME_PROFILES }
  validates :last_admission_error, :failure_code, length: { maximum: 100 }, allow_nil: true
  validates :input_context, presence: true
  validate :assignment_is_consistent
  validate :content_fits

  scope :terminal, -> { where(status: TERMINAL_STATUSES) }
  scope :active, -> { where.not(status: TERMINAL_STATUSES) }

  def active?
    !status.in?(TERMINAL_STATUSES)
  end

  private
    def assignment_is_consistent
      return if crew_task.nil? || agent_profile.nil? || agent_profile_version.nil?

      unless crew_task.workspace_id == workspace_id && agent_profile.workspace_id == workspace_id &&
          agent_profile_version.workspace_id == workspace_id && agent_profile_version.agent_profile_id == agent_profile_id
        errors.add(:agent_profile_version, "does not match this workspace and profile")
      end
      errors.add(:input_artifact, "belongs to another workspace") if input_artifact && input_artifact.workspace_id != workspace_id
    end

    def content_fits
      errors.add(:request_key, "must be 128 bytes or less") if request_key.to_s.bytesize > 128
      errors.add(:output, "must be 100 KiB or less") if output.to_s.bytesize > 100.kilobytes
      errors.add(:input_context, "must be 128 KiB or less") if input_context.to_s.bytesize > 128.kilobytes
    end
end
