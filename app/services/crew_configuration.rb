class CrewConfiguration
  class InvalidConfiguration < StandardError; end

  CREWS = {
    "support" => "Support Crew",
    "customer_success" => "Customer Success Crew"
  }.freeze

  def self.install_defaults!(workspace:)
    new(workspace:).install_defaults!
  end

  def self.update_profile!(workspace:, membership:, agent_profile:, attributes:)
    new(workspace:, membership:).update_profile!(agent_profile:, attributes:)
  end

  def initialize(workspace:, membership: nil)
    @workspace = workspace
    @membership = membership && workspace.memberships.find(membership.id)
  end

  def install_defaults!
    CrewTemplate.transaction do
      lock_workspace!
      CREWS.each do |crew_kind, name|
        crew = @workspace.crew_templates.find_or_create_by!(crew_kind:) { |record| record.name = name }
        AgentPolicy::ROLE_DEFINITIONS.each do |role_key, definition|
          next unless definition.fetch(:crew_kind) == crew_kind

          profile = @workspace.agent_profiles.find_or_create_by!(crew_template: crew, role_key:) do |record|
            record.name = definition.fetch(:name)
          end
          append_default!(profile) unless profile.current_version
        end
      end
    end
    @workspace.crew_templates.includes(agent_profiles: :current_version).order(:id)
  end

  def update_profile!(agent_profile:, attributes:)
    authorize!
    profile = @workspace.agent_profiles.find(agent_profile.id)
    expected_version_number = strict_integer(attributes[:expected_version_number])
    values = normalized_values(profile, attributes)
    if bounded_policy_changed?(profile.current_version, values)
      raise InvalidConfiguration,
        "Routing, fallback, review, and execution budgets require Governed policy preview and an explicit canary."
    end
    AgentProfile.transaction do
      profile.lock!
      unless profile.current_version.version_number == expected_version_number
        raise InvalidConfiguration, "This policy changed after the page loaded. Review the current version and try again."
      end
      return profile.current_version if same_version?(profile.current_version, values)

      version = profile.versions.create!(
        workspace: @workspace,
        version_number: profile.versions.maximum(:version_number).to_i + 1,
        **values,
        created_by_membership: @membership,
        created_by_user: @membership.user
      )
      profile.update!(current_version: version)
      AuditEvent.record!(
        action: "agent.profile_updated", source: :web, workspace: @workspace,
        actor: @membership.user, subject: version
      )
      version
    end
  rescue ActiveRecord::RecordInvalid => error
    raise InvalidConfiguration, error.record.errors.full_messages.to_sentence
  end

  private
    def append_default!(profile)
      definition = AgentPolicy.definition(profile.role_key)
      version = profile.versions.create!(
        workspace: @workspace, version_number: 1,
        instructions: definition.fetch(:instructions),
        allowed_tools: definition.fetch(:tools).sort,
        runtime_profile_key: "workspace_default", fallback_profile_keys: [],
        timeout_seconds: 300, max_steps: 10, max_tool_calls: 20,
        review_policy: "required"
      )
      profile.update!(current_version: version)
    end

    def normalized_values(profile, attributes)
      tools = Array(attributes[:allowed_tools]).compact_blank.map(&:to_s).uniq.sort
      fallbacks = Array(attributes[:fallback_profile_keys]).compact_blank.map(&:to_s)
      values = {
        instructions: attributes[:instructions].to_s.strip,
        allowed_tools: tools,
        runtime_profile_key: attributes[:runtime_profile_key].to_s,
        fallback_profile_keys: fallbacks,
        timeout_seconds: strict_integer(attributes[:timeout_seconds]),
        max_steps: strict_integer(attributes[:max_steps]),
        max_tool_calls: strict_integer(attributes[:max_tool_calls]),
        review_policy: attributes[:review_policy].to_s,
        memory_required: attributes.key?(:memory_required) ?
          ActiveModel::Type::Boolean.new.cast(attributes[:memory_required]) : profile.current_version.memory_required
      }
      candidate = profile.versions.build(workspace: @workspace, version_number: 1, **values)
      raise InvalidConfiguration, candidate.errors.full_messages.to_sentence unless candidate.valid?

      values
    end

    def same_version?(version, values)
      values.all? { |attribute, value| version.public_send(attribute) == value }
    end

    def bounded_policy_changed?(version, values)
      GovernedPolicyChange::PROFILE_POLICY_FIELDS.any? do |attribute|
        version.public_send(attribute) != values.fetch(attribute)
      end
    end

    def strict_integer(value)
      Integer(value.to_s, 10)
    rescue ArgumentError, TypeError
      raise InvalidConfiguration, "Budgets must be whole numbers."
    end

    def authorize!
      raise Current::RoleAccessDenied unless @membership&.can_configure_agents?
    end

    def lock_workspace!
      quoted = CrewTemplate.connection.quote("crew-configuration:#{@workspace.id}")
      CrewTemplate.connection.execute("SELECT pg_advisory_xact_lock(hashtext(#{quoted}))")
    end
end
