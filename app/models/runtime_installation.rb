class RuntimeInstallation < ApplicationRecord
  KNOWN_TRANSPORTS = %w[built_in_https managed_process].freeze
  LEGACY_TRANSPORT = "legacy_unknown"
  TRANSPORTS = (KNOWN_TRANSPORTS + [ LEGACY_TRANSPORT ]).freeze
  KNOWN_EXECUTION_MODES = %w[bounded host_trusted strong_isolated].freeze
  LEGACY_EXECUTION_MODE = "legacy_unknown"
  EXECUTION_MODES = (KNOWN_EXECUTION_MODES + [ LEGACY_EXECUTION_MODE ]).freeze
  COMPATIBILITY_STATUSES = %w[compatible warning incompatible unknown].freeze
  HEALTH_STATUSES = %w[available unhealthy missing].freeze
  RUNTIME_TEST_STATUSES = %w[untested passed failed].freeze
  FINGERPRINT_FORMAT = /\A[0-9a-f]{64}\z/
  FAILURE_CODE_FORMAT = /\A[a-z][a-z0-9_]{0,99}\z/
  DATA_CLASSES = {
    "case_content" => "Case content",
    "customer_identity" => "Customer identity",
    "account_context" => "Account context",
    "approved_knowledge" => "Approved knowledge",
    "public_web_query" => "Public web query",
    "retrieved_memory" => "Retrieved memory"
  }.freeze
  SENSITIVE_METADATA_KEY = /passw|secret|token|credential|cookie|authorization|private|session/i

  belongs_to :personal_provider_account, optional: true
  belongs_to :workspace
  belongs_to :approved_by_membership, class_name: "Membership", optional: true
  belongs_to :approved_by_user, class_name: "User", optional: true

  before_validation :reset_approval_for_execution_boundary_change, if: -> {
    persisted? && (execution_mode_changed? || transport_changed?)
  }

  validates :detection_key, format: { with: /\A[0-9a-f]{64}\z/ }, uniqueness: { scope: :workspace_id }
  validates :transport, inclusion: { in: TRANSPORTS }
  validates :execution_mode, inclusion: { in: EXECUTION_MODES }
  validates :adapter_key, format: { with: RunnerProtocol::POLICY_KEY_PATTERN }
  validates :protocol_version, format: { with: /\Av[1-9][0-9]*\z/ }
  validates :executable_path, presence: true, length: { maximum: 4_096 }, format: { with: %r{\A/.+\z} }
  validates :executable_version, presence: true, length: { maximum: 8.kilobytes }
  validates :minimum_version, :maximum_version, length: { maximum: 100 }
  validates :incompatibility_reason, length: { maximum: 1_000 }
  validates :compatibility_status, inclusion: { in: COMPATIBILITY_STATUSES }
  validates :health_status, inclusion: { in: HEALTH_STATUSES }
  validates :checked_at, presence: true
  validates :effective_model, presence: true, length: { maximum: 200 }, format: { without: /[\r\n\x00]/ }
  validates :configuration_fingerprint, format: { with: FINGERPRINT_FORMAT }
  validates :runtime_test_status, inclusion: { in: RUNTIME_TEST_STATUSES }
  validates :runtime_test_failure_code, format: { with: FAILURE_CODE_FORMAT }, allow_nil: true
  validates :runtime_tested_configuration_fingerprint, format: { with: FINGERPRINT_FORMAT }, allow_nil: true
  validates :runtime_test_input_units, :runtime_test_output_units,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :max_timeout_seconds, inclusion: { in: AgentProfileVersion::TIMEOUT_RANGE }
  validates :max_steps, inclusion: { in: AgentProfileVersion::STEP_RANGE }
  validates :max_tool_calls, inclusion: { in: AgentProfileVersion::TOOL_CALL_RANGE }
  validates :max_input_units, :max_output_units,
    numericality: { only_integer: true, in: 1..10_000_000 }
  validate :metadata_is_non_secret
  validate :policy_is_bounded
  validate :approval_is_complete
  validate :runtime_test_evidence_is_complete
  validate :transport_and_execution_mode_are_compatible
  validate :legacy_execution_boundary_is_not_approved

  scope :shared, -> { where(personal_provider_account_id: nil) }

  scope :ordered, -> { order(:adapter_key, :id) }

  def self.current_for_provider(candidates, provider)
    return if candidates.empty?

    model = provider.fetch("model").presence
    version = provider.fetch("executable_version").presence
    execution_mode = provider.fetch("execution_mode").presence
    return if model.blank? && version.blank? || execution_mode.blank?

    candidates = candidates.select { |installation| installation.effective_model == model } if model
    candidates = candidates.select { |installation| installation.executable_version == version } if version
    candidates = candidates.select { |installation| installation.execution_mode == execution_mode }
    return if candidates.empty?

    built_in = candidates.select { |installation| installation.transport == "built_in_https" }
    candidates = if provider.fetch("auth_mode") == "api_key"
      built_in
    else
      candidates - built_in
    end
    return if candidates.empty?

    candidates = candidates.reject { |installation| installation.health_status == "missing" }
    return if candidates.empty?

    healthy = candidates.select do |installation|
      installation.health_status == "available" && installation.compatibility_status != "incompatible"
    end
    candidates = healthy if healthy.any?

    candidates.max_by { |installation| [ installation.checked_at.to_i, installation.id ] }
  end

  def runnable?
    approved? && transport.in?(KNOWN_TRANSPORTS) && execution_mode.in?(KNOWN_EXECUTION_MODES) && transport_execution_mode_compatible? && health_status == "available" && compatibility_status != "incompatible" &&
      runtime_test_status == "passed" && runtime_tested_configuration_fingerprint == configuration_fingerprint
  end

  private
    def reset_approval_for_execution_boundary_change
      self.approved = false
      self.approved_by_membership = nil
      self.approved_by_user = nil
      self.approved_at = nil
      self.runtime_test_status = "untested"
      self.runtime_test_failure_code = nil
      self.runtime_tested_at = nil
      self.runtime_tested_configuration_fingerprint = nil
      self.runtime_test_input_units = 0
      self.runtime_test_output_units = 0
      self.runtime_test_usage_observed = false
    end

    def legacy_execution_boundary_is_not_approved
      if execution_mode == LEGACY_EXECUTION_MODE && approved?
        errors.add(:approved, "cannot be approved until execution mode is known")
      elsif transport == LEGACY_TRANSPORT && approved?
        errors.add(:approved, "cannot be approved until runtime transport is known")
      end
    end

    def metadata_is_non_secret
      unless account_metadata.is_a?(Hash) && account_metadata.size <= 16 && account_metadata.to_json.bytesize <= 8.kilobytes &&
          account_metadata.values.all? { |value| value.is_a?(String) && value.bytesize <= 500 }
        errors.add(:account_metadata, "must contain short non-secret text values")
        return
      end
      errors.add(:account_metadata, "contains a secret-like field") if account_metadata.keys.any? { |key| key.match?(SENSITIVE_METADATA_KEY) }
    end

    def policy_is_bounded
      validate_values(:capabilities, capabilities, 32, nil)
      validate_values(:allowed_role_keys, allowed_role_keys, 8, AgentPolicy::ROLE_DEFINITIONS.keys)
      validate_values(:allowed_tools, allowed_tools, AgentPolicy::TOOLS.size, AgentPolicy::TOOLS.keys)
      validate_values(:allowed_data_classes, allowed_data_classes, 8, DATA_CLASSES.keys)
      validate_values(:profile_keys, profile_keys, AgentPolicy::RUNTIME_PROFILES.size, AgentPolicy::RUNTIME_PROFILES.keys)
    end

    def validate_values(attribute, values, maximum, allowed)
      valid = values.is_a?(Array) && values.size <= maximum && values == values.uniq.sort &&
        values.all? { |value| value.is_a?(String) && value.match?(RunnerProtocol::POLICY_KEY_PATTERN) }
      valid &&= (values - allowed).empty? if allowed
      errors.add(attribute, "is invalid") unless valid
    end

    def approval_is_complete
      actor_present = approved_by_membership_id.present? && approved_by_user_id.present? && approved_at.present?
      actor_absent = approved_by_membership_id.nil? && approved_by_user_id.nil? && approved_at.nil?
      errors.add(:approved, "must have one approving actor and time") unless approved? ? actor_present : actor_absent
      if approved? && (runtime_test_status != "passed" || runtime_tested_configuration_fingerprint != configuration_fingerprint)
        errors.add(:approved, "requires a passing test of the current configuration")
      end
    end

    def runtime_test_evidence_is_complete
      if runtime_test_status == "untested"
        valid = runtime_test_failure_code.nil? && runtime_tested_at.nil? &&
          runtime_tested_configuration_fingerprint.nil? && runtime_test_input_units.zero? &&
          runtime_test_output_units.zero? && !runtime_test_usage_observed?
      else
        valid = runtime_tested_at.present? && runtime_tested_configuration_fingerprint == configuration_fingerprint
        valid &&= runtime_test_status == "passed" ? runtime_test_failure_code.nil? : runtime_test_failure_code.present?
      end
      errors.add(:runtime_test_status, "does not match its evidence") unless valid
    end

    def transport_and_execution_mode_are_compatible
      return unless KNOWN_TRANSPORTS.include?(transport) && KNOWN_EXECUTION_MODES.include?(execution_mode)

      valid = transport_execution_mode_compatible?
      errors.add(:execution_mode, "is incompatible with runtime transport") unless valid
    end

    def transport_execution_mode_compatible?
      case transport
      when "built_in_https"
        execution_mode == "bounded"
      when "managed_process"
        execution_mode.in?(%w[host_trusted strong_isolated])
      else
        false
      end
    end
end
