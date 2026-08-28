class AgentProfileVersion < ApplicationRecord
  MAX_INSTRUCTION_BYTES = 8_000
  TIMEOUT_RANGE = 30..900
  STEP_RANGE = 1..20
  TOOL_CALL_RANGE = 0..50

  belongs_to :workspace
  belongs_to :agent_profile
  belongs_to :created_by_membership, class_name: "Membership", optional: true
  belongs_to :created_by_user, class_name: "User", optional: true
  has_many :governed_policy_proposals, dependent: :restrict_with_exception

  validates :version_number, numericality: { only_integer: true, greater_than: 0 }
  validates :instructions, presence: true
  validates :runtime_profile_key, inclusion: { in: AgentPolicy::RUNTIME_PROFILES }
  validates :review_policy, inclusion: { in: AgentPolicy::REVIEW_POLICIES }
  validates :timeout_seconds, numericality: { only_integer: true, in: TIMEOUT_RANGE }
  validates :max_steps, numericality: { only_integer: true, in: STEP_RANGE }
  validates :max_tool_calls, numericality: { only_integer: true, in: TOOL_CALL_RANGE }
  validate :instructions_fit
  validate :tools_stay_within_role
  validate :fallback_order_is_safe
  validate :actor_is_consistent

  def readonly?
    persisted?
  end

  private
    def instructions_fit
      errors.add(:instructions, "must be 8,000 bytes or less") if instructions.to_s.bytesize > MAX_INSTRUCTION_BYTES
    end

    def tools_stay_within_role
      unless allowed_tools.is_a?(Array) && allowed_tools.uniq == allowed_tools &&
          (allowed_tools - AgentPolicy.tools_for(agent_profile&.role_key)).empty?
        errors.add(:allowed_tools, "exceed this role's approved tools")
      end
    rescue KeyError
      errors.add(:allowed_tools, "cannot be checked without a role")
    end

    def fallback_order_is_safe
      unless fallback_profile_keys.is_a?(Array) && fallback_profile_keys.uniq == fallback_profile_keys &&
          fallback_profile_keys.size <= 2 &&
          (fallback_profile_keys - AgentPolicy::RUNTIME_PROFILES.keys).empty? &&
          fallback_profile_keys.exclude?(runtime_profile_key)
        errors.add(:fallback_profile_keys, "must contain distinct approved profiles after the primary profile")
      end
    end

    def actor_is_consistent
      if created_by_membership.nil? != created_by_user.nil?
        errors.add(:created_by_membership, "and user must both be set")
      elsif created_by_membership &&
          (created_by_membership.workspace_id != workspace_id || created_by_membership.user != created_by_user)
        errors.add(:created_by_membership, "does not match workspace and user")
      end
    end
end
