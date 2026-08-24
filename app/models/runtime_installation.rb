class RuntimeInstallation < ApplicationRecord
  COMPATIBILITY_STATUSES = %w[compatible warning incompatible unknown].freeze
  HEALTH_STATUSES = %w[available unhealthy missing].freeze
  DATA_CLASSES = {
    "case_content" => "Case content",
    "customer_identity" => "Customer identity",
    "account_context" => "Account context",
    "approved_knowledge" => "Approved knowledge",
    "public_web_query" => "Public web query"
  }.freeze
  SENSITIVE_METADATA_KEY = /passw|secret|token|credential|cookie|authorization|private|session/i

  belongs_to :workspace
  belongs_to :approved_by_membership, class_name: "Membership", optional: true
  belongs_to :approved_by_user, class_name: "User", optional: true

  validates :detection_key, format: { with: /\A[0-9a-f]{64}\z/ }, uniqueness: { scope: :workspace_id }
  validates :adapter_key, format: { with: RunnerProtocol::POLICY_KEY_PATTERN }
  validates :protocol_version, format: { with: /\Av[1-9][0-9]*\z/ }
  validates :executable_path, presence: true, length: { maximum: 4_096 }, format: { with: %r{\A/.+\z} }
  validates :executable_version, presence: true, length: { maximum: 8.kilobytes }
  validates :minimum_version, :maximum_version, length: { maximum: 100 }
  validates :incompatibility_reason, length: { maximum: 1_000 }
  validates :compatibility_status, inclusion: { in: COMPATIBILITY_STATUSES }
  validates :health_status, inclusion: { in: HEALTH_STATUSES }
  validates :checked_at, presence: true
  validates :max_timeout_seconds, inclusion: { in: AgentProfileVersion::TIMEOUT_RANGE }
  validates :max_steps, inclusion: { in: AgentProfileVersion::STEP_RANGE }
  validates :max_tool_calls, inclusion: { in: AgentProfileVersion::TOOL_CALL_RANGE }
  validate :metadata_is_non_secret
  validate :policy_is_bounded
  validate :approval_is_complete

  scope :ordered, -> { order(:adapter_key, :id) }

  def runnable?
    approved? && health_status == "available" && compatibility_status != "incompatible"
  end

  private
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
      validate_values(:allowed_tools, allowed_tools, 8, AgentPolicy::TOOLS.keys)
      validate_values(:allowed_data_classes, allowed_data_classes, 8, DATA_CLASSES.keys)
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
    end
end
