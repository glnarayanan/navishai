class ExecutionRun < ApplicationRecord
  LEGACY_EXECUTION_MODE = RuntimeInstallation::LEGACY_EXECUTION_MODE
  LEGACY_ISOLATION_POLICY = AgentPolicy::LEGACY_ISOLATION_POLICY
  STATUSES = %w[admitting admitted running completed failed timed_out canceled policy_denied].freeze
  TERMINAL_STATUSES = %w[completed failed timed_out canceled policy_denied].freeze
  MEMORY_CONTEXT_STATUSES = %w[not_applicable available degraded].freeze

  attribute :run_key, default: -> { SecureRandom.uuid }

  belongs_to :requested_by_membership, class_name: "Membership", optional: true
  belongs_to :workspace
  belongs_to :crew_task
  belongs_to :agent_profile
  belongs_to :agent_profile_version
  belongs_to :governed_policy_publication, optional: true
  belongs_to :resolution_contract_version, optional: true
  belongs_to :runtime_installation, optional: true
  belongs_to :usage_rate_version, optional: true
  belongs_to :current_event, class_name: "ExecutionEvent", optional: true
  belongs_to :input_artifact, class_name: "CrewArtifact", optional: true
  has_many :events, -> { order(:sequence_number) }, class_name: "ExecutionEvent", dependent: :restrict_with_exception
  has_one :crew_artifact, dependent: :restrict_with_exception
  has_one :health_scorecard_proposal, dependent: :restrict_with_exception
  has_many :execution_memory_selections, -> { order(:rank) }, dependent: :restrict_with_exception
  has_many :retrieved_memory_records, through: :execution_memory_selections, source: :memory_record
  has_one :usage_cost_snapshot, dependent: :restrict_with_exception

  enum :status, STATUSES.index_by(&:itself), validate: true
  enum :memory_context_status, MEMORY_CONTEXT_STATUSES.index_by(&:itself), validate: true, prefix: :memory

  validates :run_key, presence: true, uniqueness: true
  validates :request_key, presence: true, length: { maximum: 128 }, uniqueness: { scope: :workspace_id }
  validates :attempt_number, numericality: { only_integer: true, greater_than: 0 }
  validates :current_sequence, :admission_attempt_count, :input_units, :output_units,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :runtime_profile_key, inclusion: { in: AgentPolicy::RUNTIME_PROFILES }
  validates :selected_runtime_profile_key, inclusion: { in: AgentPolicy::RUNTIME_PROFILES }
  validates :runtime_selection_reason, inclusion: { in: %w[primary fallback] }
  validates :runtime_selection_detail, presence: true, length: { maximum: 500 }
  validates :memory_context_detail, presence: true, length: { maximum: 100 }, if: :memory_degraded?
  validates :memory_context_detail, absence: true, unless: :memory_degraded?
  validates :selected_runtime_detection_key, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :selected_runtime_configuration_fingerprint, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :selected_effective_model, presence: true, length: { maximum: 200 },
    format: { without: /[\r\n]/ }
  validates :selected_execution_mode, inclusion: { in: RuntimeInstallation::EXECUTION_MODES }
  validates :selected_isolation_policy, inclusion: { in: AgentPolicy::ISOLATION_POLICIES.keys + [ LEGACY_ISOLATION_POLICY ] }
  validates :selected_adapter_key, format: { with: RunnerProtocol::POLICY_KEY_PATTERN }
  validates :max_input_units, :max_output_units,
    numericality: { only_integer: true, in: 1..10_000_000 }
  validate :disclosure_is_bounded
  validates :last_admission_error, :failure_code, length: { maximum: 100 }, allow_nil: true
  validates :input_context, presence: true
  validate :assignment_is_consistent
  validate :content_fits
  validate :execution_boundary_is_usable, on: :create
  validate :execution_boundary_matches_assignments, on: :create
  before_validation :populate_execution_boundary, on: :create

  scope :terminal, -> { where(status: TERMINAL_STATUSES) }
  scope :active, -> { where.not(status: TERMINAL_STATUSES) }

  def active?
    !status.in?(TERMINAL_STATUSES)
  end

  private
    def populate_execution_boundary
      self.selected_execution_mode = runtime_installation.execution_mode if
        runtime_installation && selected_execution_mode.in?([ nil, LEGACY_EXECUTION_MODE ])
      self.selected_isolation_policy = agent_profile_version.isolation_policy if
        agent_profile_version && selected_isolation_policy.in?([ nil, LEGACY_ISOLATION_POLICY ])
    end

    def execution_boundary_is_usable
      if selected_execution_mode == LEGACY_EXECUTION_MODE || selected_isolation_policy == LEGACY_ISOLATION_POLICY
        errors.add(:selected_execution_mode, "must be known for a new run")
      elsif !AgentPolicy.execution_mode_allowed?(selected_isolation_policy, selected_execution_mode)
        errors.add(:selected_execution_mode, "is not allowed by the selected isolation policy")
      end
    end

    def execution_boundary_matches_assignments
      if runtime_installation && selected_execution_mode != runtime_installation.execution_mode
        errors.add(:selected_execution_mode, "must match the selected runtime installation")
      end
      if agent_profile_version && selected_isolation_policy != agent_profile_version.isolation_policy
        errors.add(:selected_isolation_policy, "must match the selected profile version")
      end
    end

    def assignment_is_consistent
      return if crew_task.nil? || agent_profile.nil? || agent_profile_version.nil?

      unless crew_task.workspace_id == workspace_id && agent_profile.workspace_id == workspace_id &&
          agent_profile_version.workspace_id == workspace_id && agent_profile_version.agent_profile_id == agent_profile_id
        errors.add(:agent_profile_version, "does not match this workspace and profile")
      end
      errors.add(:input_artifact, "belongs to another workspace") if input_artifact && input_artifact.workspace_id != workspace_id
      errors.add(:governed_policy_publication, "belongs to another workspace") if
        governed_policy_publication && governed_policy_publication.workspace_id != workspace_id
      errors.add(:resolution_contract_version, "belongs to another workspace") if
        resolution_contract_version && resolution_contract_version.workspace_id != workspace_id
      errors.add(:runtime_installation, "belongs to another workspace") if runtime_installation && runtime_installation.workspace_id != workspace_id
      errors.add(:usage_rate_version, "belongs to another workspace") if usage_rate_version && usage_rate_version.workspace_id != workspace_id
      if governed_policy_publication &&
          (governed_policy_publication.resolution_contract_version_id != resolution_contract_version_id ||
          governed_policy_publication.agent_profile_version_id != agent_profile_version_id)
        errors.add(:governed_policy_publication, "does not match the frozen contract and profile")
      end
      if crew_task && crew_task.assigned_agent_profile_version_id != agent_profile_version_id
        errors.add(:crew_task, "does not match the frozen profile")
      end
      if crew_task && crew_task.resolution_contract_version_id != resolution_contract_version_id
        errors.add(:crew_task, "does not match the frozen contract")
      end
      if crew_task && crew_task.governed_policy_publication_id != governed_policy_publication_id
        errors.add(:crew_task, "does not match the frozen publication")
      end
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
