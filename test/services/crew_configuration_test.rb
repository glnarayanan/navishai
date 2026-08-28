require "test_helper"

class CrewConfigurationTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
    CrewConfiguration.install_defaults!(workspace: @workspace)
  end

  test "installs the opinionated Support and Customer Success crews idempotently" do
    assert_no_difference [ "CrewTemplate.count", "AgentProfile.count", "AgentProfileVersion.count" ] do
      CrewConfiguration.install_defaults!(workspace: @workspace)
    end

    crews = @workspace.crew_templates.includes(agent_profiles: :current_version).order(:crew_kind)
    assert_equal %w[customer_success support], crews.map(&:crew_kind)
    assert_equal 8, crews.sum { |crew| crew.agent_profiles.size }
    assert crews.flat_map(&:agent_profiles).all?(&:current_version)
    assert_not_includes AgentPolicy::TOOLS, "customer_send"
  end

  test "an Admin can version instructions and tools but bounded policy requires governed preview" do
    admin_user = User.create!(
      email_address: "crew-admin@example.com", password: "password12345", verified_at: Time.current
    )
    admin = @workspace.memberships.create!(user: admin_user, role: :admin)
    profile = @workspace.agent_profiles.find_by!(role_key: "support_investigator")
    original = profile.current_version

    version = CrewConfiguration.update_profile!(
      workspace: @workspace, membership: admin, agent_profile: profile,
      attributes: {
        expected_version_number: original.version_number,
        instructions: "Investigate with current evidence and state every material uncertainty.",
        allowed_tools: %w[conversation_read case_read knowledge_search],
        runtime_profile_key: original.runtime_profile_key, fallback_profile_keys: original.fallback_profile_keys,
        timeout_seconds: original.timeout_seconds, max_steps: original.max_steps,
        max_tool_calls: original.max_tool_calls, review_policy: original.review_policy
      }
    )

    assert_equal 2, version.version_number
    assert_equal %w[case_read conversation_read knowledge_search], version.allowed_tools
    assert_equal original.fallback_profile_keys, version.fallback_profile_keys
    assert_equal admin, version.created_by_membership
    assert_equal admin_user, version.created_by_user
    assert_equal version, profile.reload.current_version
    assert_equal AgentPolicy.definition(profile.role_key).fetch(:instructions), original.reload.instructions
    assert AuditEvent.where(
      action: "agent.profile_updated", actor: admin_user,
      subject_type: "AgentProfileVersion", subject_id: version.id
    ).exists?

    assert_no_difference [ "AgentProfileVersion.count", "AuditEvent.count" ] do
      assert_raises(CrewConfiguration::InvalidConfiguration) do
        CrewConfiguration.update_profile!(
          workspace: @workspace, membership: admin, agent_profile: profile,
          attributes: attributes_for(version).merge(runtime_profile_key: "thorough")
        )
      end
    end

    assert_no_difference [ "AgentProfileVersion.count", "AuditEvent.count" ] do
      CrewConfiguration.update_profile!(
        workspace: @workspace, membership: admin, agent_profile: profile,
        attributes: version.attributes.symbolize_keys.slice(
          :instructions, :allowed_tools, :runtime_profile_key, :fallback_profile_keys,
          :timeout_seconds, :max_steps, :max_tool_calls, :review_policy
        ).merge(expected_version_number: version.version_number)
      )
    end
    assert_no_difference [ "AgentProfileVersion.count", "AuditEvent.count" ] do
      assert_raises(CrewConfiguration::InvalidConfiguration) do
        CrewConfiguration.update_profile!(
          workspace: @workspace, membership: admin, agent_profile: profile,
          attributes: attributes_for(version).merge(
            expected_version_number: original.version_number,
            instructions: "Stale policy edit"
          )
        )
      end
    end
    audit_failure = ActiveRecord::RecordInvalid.new(AuditEvent.new)
    original_record = AuditEvent.method(:record!)
    AuditEvent.define_singleton_method(:record!) { |**| raise audit_failure }
    begin
      assert_no_difference [ "AgentProfileVersion.count", "AuditEvent.count" ] do
        assert_raises(CrewConfiguration::InvalidConfiguration) do
          CrewConfiguration.update_profile!(
            workspace: @workspace, membership: admin, agent_profile: profile,
            attributes: attributes_for(version).merge(instructions: "Must roll back")
          )
        end
      end
    ensure
      AuditEvent.define_singleton_method(:record!, original_record)
    end
    assert_equal version, profile.reload.current_version
  end

  test "non-admins and out-of-policy changes cannot expand agent authority" do
    manager_user = User.create!(
      email_address: "crew-manager@example.com", password: "password12345", verified_at: Time.current
    )
    manager = @workspace.memberships.create!(user: manager_user, role: :manager)
    profile = @workspace.agent_profiles.find_by!(role_key: "resolution_drafter")
    baseline = attributes_for(profile.current_version)

    assert_raises(Current::RoleAccessDenied) do
      CrewConfiguration.update_profile!(
        workspace: @workspace, membership: manager, agent_profile: profile, attributes: baseline
      )
    end
    assert_raises(CrewConfiguration::InvalidConfiguration) do
      CrewConfiguration.update_profile!(
        workspace: @workspace, membership: @owner, agent_profile: profile,
        attributes: baseline.merge(allowed_tools: baseline[:allowed_tools] + [ "review_record" ])
      )
    end
    assert_raises(CrewConfiguration::InvalidConfiguration) do
      CrewConfiguration.update_profile!(
        workspace: @workspace, membership: @owner, agent_profile: profile,
        attributes: baseline.merge(timeout_seconds: 901)
      )
    end
    assert_raises(CrewConfiguration::InvalidConfiguration) do
      CrewConfiguration.update_profile!(
        workspace: @workspace, membership: @owner, agent_profile: profile,
        attributes: baseline.merge(runtime_profile_key: "arbitrary-command")
      )
    end
  end

  test "tenant and PostgreSQL policy boundaries fail closed" do
    profile = @workspace.agent_profiles.find_by!(role_key: "support_coordinator")
    foreign_user = User.create!(
      email_address: "foreign-crew-owner@example.com", password: "password12345", verified_at: Time.current
    )
    foreign_owner = workspaces(:beta_support).memberships.create!(user: foreign_user, role: :owner)
    assert_raises(ActiveRecord::RecordNotFound) do
      CrewConfiguration.update_profile!(
        workspace: workspaces(:beta_support), membership: foreign_owner,
        agent_profile: profile, attributes: attributes_for(profile.current_version)
      )
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      AgentProfileVersion.transaction(requires_new: true) do
        AgentProfileVersion.where(id: profile.current_version_id).update_all(instructions: "Changed")
      end
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      AgentProfileVersion.insert_all!([ {
        workspace_id: @workspace.id, version_number: 99, instructions: "Unsafe",
        agent_profile_id: profile.id,
        allowed_tools: [ "review_record" ], runtime_profile_key: "fast",
        fallback_profile_keys: [], timeout_seconds: 60, max_steps: 2,
        max_tool_calls: 2, review_policy: "required",
        created_at: Time.current, updated_at: Time.current
      } ])
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      AgentProfile.insert_all!([ {
        workspace_id: @workspace.id, crew_template_id: profile.crew_template_id,
        role_key: "account_analyst", name: "Wrong crew",
        created_at: Time.current, updated_at: Time.current
      } ])
    end
  end

  test "new workspaces receive defaults and workspace deletion removes only their configuration" do
    organization = Organization.create!(name: "Crew test", slug: "crew-test")
    workspace = organization.workspaces.create!(name: "Crew test", slug: "crew-test")

    assert_equal 2, workspace.crew_templates.count
    assert_equal 8, workspace.agent_profiles.count
    profile_ids = workspace.agent_profiles.ids

    workspace.delete

    assert_empty CrewTemplate.where(workspace_id: workspace.id)
    assert_empty AgentProfile.where(id: profile_ids)
    assert @workspace.crew_templates.exists?
  end

  private
    def attributes_for(version)
      version.attributes.symbolize_keys.slice(
        :instructions, :allowed_tools, :runtime_profile_key, :fallback_profile_keys,
        :timeout_seconds, :max_steps, :max_tool_calls, :review_policy
      ).merge(expected_version_number: version.version_number)
    end
end
