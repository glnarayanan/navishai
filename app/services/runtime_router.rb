class RuntimeRouter
  class NoCompatibleRuntime < StandardError; end

  Selection = Data.define(
    :installation, :profile_key, :reason, :detail, :data_classes, :max_input_units, :max_output_units
  )

  def self.resolve!(workspace:, profile_version:, additional_data_classes: [])
    new(workspace:).resolve!(profile_version:, additional_data_classes:)
  end

  def initialize(workspace:)
    @workspace = workspace
  end

  def resolve!(profile_version:, additional_data_classes: [])
    version = @workspace.agent_profile_versions.includes(:agent_profile).find(profile_version.id)
    profiles = [ version.runtime_profile_key, *version.fallback_profile_keys ]
    unless (additional_data_classes - RuntimeInstallation::DATA_CLASSES.keys).empty?
      raise ArgumentError, "additional data class is invalid"
    end
    data_classes = (data_classes_for(version) + additional_data_classes).uniq.sort
    required_capabilities = [ "structured_output" ]
    required_capabilities << "tool_calling" if version.allowed_tools.any?
    rejections = []
    installations = @workspace.runtime_installations.ordered.lock.to_a

    profiles.each_with_index do |profile_key, index|
      installations.each do |installation|
        reasons = rejection_reasons(
          installation:, version:, profile_key:, data_classes:, required_capabilities:
        )
        if reasons.empty?
          fallback = index.positive?
          detail = if fallback
            cause = rejections.uniq.first(2).join("; ").presence || "no approved runtime was assigned"
            "#{AgentPolicy::RUNTIME_PROFILES.fetch(version.runtime_profile_key)} was unavailable (#{cause}); selected #{AgentPolicy::RUNTIME_PROFILES.fetch(profile_key)}."
          else
            "Primary #{AgentPolicy::RUNTIME_PROFILES.fetch(profile_key)} profile selected."
          end
          return Selection.new(
            installation:, profile_key:, reason: fallback ? "fallback" : "primary", detail:,
            data_classes:, max_input_units: installation.max_input_units,
            max_output_units: installation.max_output_units
          )
        end
        rejections.concat(reasons.map { |reason| "#{installation.adapter_key}: #{reason}" })
      end
    end
    detail = rejections.uniq.first(3).join("; ").presence || "No approved runtime is assigned to the requested profiles."
    raise NoCompatibleRuntime, "No compatible runtime can run this task. #{detail}"
  end

  private
    def rejection_reasons(installation:, version:, profile_key:, data_classes:, required_capabilities:)
      reasons = []
      reasons << "not runnable" unless installation.runnable?
      reasons << "profile not assigned" unless installation.profile_keys.include?(profile_key)
      reasons << "role not allowed" unless installation.allowed_role_keys.include?(version.agent_profile.role_key)
      reasons << "tools not allowed" unless (version.allowed_tools - installation.allowed_tools).empty?
      reasons << "data not allowed" unless (data_classes - installation.allowed_data_classes).empty?
      reasons << "capability mismatch" unless (required_capabilities - installation.capabilities).empty?
      reasons << "timeout budget exceeded" if version.timeout_seconds > installation.max_timeout_seconds
      reasons << "step budget exceeded" if version.max_steps > installation.max_steps
      reasons << "tool-call budget exceeded" if version.max_tool_calls > installation.max_tool_calls
      reasons
    end

    def data_classes_for(version)
      values = []
      role_key = version.agent_profile.role_key
      values << (role_key.start_with?("support_", "resolution_") ? "case_content" : "account_context")
      values << "customer_identity" if version.allowed_tools.include?("conversation_read")
      values << "approved_knowledge" if version.allowed_tools.include?("knowledge_search")
      values << "public_web_query" if version.allowed_tools.include?("public_web_search")
      values.uniq.sort
    end
end
