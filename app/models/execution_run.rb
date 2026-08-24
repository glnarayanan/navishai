class ExecutionRun < ApplicationRecord
  STATUSES = %w[admitting admitted running completed failed timed_out canceled policy_denied].freeze
  TERMINAL_STATUSES = %w[completed failed timed_out canceled policy_denied].freeze

  attribute :run_key, default: -> { SecureRandom.uuid }

  belongs_to :workspace
  belongs_to :crew_task
  belongs_to :agent_profile
  belongs_to :agent_profile_version
  belongs_to :runtime_installation, optional: true
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
  validates :selected_runtime_profile_key, inclusion: { in: AgentPolicy::RUNTIME_PROFILES }
  validates :runtime_selection_reason, inclusion: { in: %w[primary fallback] }
  validates :runtime_selection_detail, presence: true, length: { maximum: 500 }
  validates :selected_runtime_detection_key, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :selected_adapter_key, format: { with: RunnerProtocol::POLICY_KEY_PATTERN }
  validates :max_input_units, :max_output_units,
    numericality: { only_integer: true, in: 1..10_000_000 }
  validate :disclosure_is_bounded
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
      errors.add(:runtime_installation, "belongs to another workspace") if runtime_installation && runtime_installation.workspace_id != workspace_id
    end

    def content_fits
      errors.add(:request_key, "must be 128 bytes or less") if request_key.to_s.bytesize > 128
      errors.add(:output, "must be 100 KiB or less") if output.to_s.bytesize > 100.kilobytes
      errors.add(:input_context, "must be 128 KiB or less") if input_context.to_s.bytesize > 128.kilobytes
    end

    def disclosure_is_bounded
      unless disclosed_data_classes.is_a?(Array) && disclosed_data_classes == disclosed_data_classes.uniq.sort &&
          (disclosed_data_classes - RuntimeInstallation::DATA_CLASSES.keys).empty?
        errors.add(:disclosed_data_classes, "is invalid")
      end
    end
end
