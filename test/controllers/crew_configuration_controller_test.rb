require "test_helper"

class CrewConfigurationControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:acme_support)
    CrewConfiguration.install_defaults!(workspace: @workspace)
    @crew = @workspace.crew_templates.find_by!(crew_kind: :support)
    @profile = @crew.agent_profiles.find_by!(role_key: "support_investigator")
  end

  test "members inspect bounded crew policy while only Admins can edit" do
    member_user = User.create!(
      email_address: "crew-member@example.com", password: "password12345", verified_at: Time.current
    )
    @workspace.memberships.create!(user: member_user, role: :member)
    sign_in_as member_user

    get workspace_crew_templates_path(@workspace)

    assert_response :success
    assert_select "h1", "Specialist crews"
    assert_select ".crew-section", count: 2
    assert_select ".agent-profile", count: 8
    assert_select ".agent-policy-form", count: 0

    patch workspace_crew_template_agent_profile_path(@workspace, @crew, @profile), params: {
      agent_profile: attributes_for(@profile.current_version)
    }
    assert_response :forbidden
  end

  test "an Owner appends a policy version through the bounded form" do
    sign_in_as users(:owner)

    assert_difference [ "AgentProfileVersion.count", "AuditEvent.count" ], 1 do
      patch workspace_crew_template_agent_profile_path(@workspace, @crew, @profile), params: {
        agent_profile: attributes_for(@profile.current_version).merge(
          instructions: "Investigate against current, cited evidence and state uncertainty.",
          allowed_tools: %w[case_read conversation_read knowledge_search],
          runtime_profile_key: "thorough", fallback_profile_keys: [ "fast", "" ],
          timeout_seconds: "360", max_steps: "12", max_tool_calls: "18"
        )
      }
    end

    assert_redirected_to workspace_crew_templates_path(@workspace, anchor: "profile-#{@profile.id}")
    version = @profile.reload.current_version
    assert_equal 2, version.version_number
    assert_equal "thorough", version.runtime_profile_key
    assert_equal [ "fast" ], version.fallback_profile_keys
    assert_equal users(:owner), version.created_by_user
  end

  test "invalid policy rerenders the open editor without losing entered values" do
    sign_in_as users(:owner)

    assert_no_difference [ "AgentProfileVersion.count", "AuditEvent.count" ] do
      patch workspace_crew_template_agent_profile_path(@workspace, @crew, @profile), params: {
        agent_profile: attributes_for(@profile.current_version).merge(
          instructions: "Keep this entered text",
          fallback_profile_keys: %w[fast fast]
        )
      }
    end

    assert_response :unprocessable_content
    assert_select "#profile-#{@profile.id}[open]"
    assert_select ".inline-error", text: /distinct approved profiles/
    assert_select "#profile-#{@profile.id} textarea", text: "Keep this entered text"
  end

  test "foreign crew and profile paths fail closed" do
    sign_in_as users(:owner)
    CrewConfiguration.install_defaults!(workspace: workspaces(:beta_support))
    foreign_crew = workspaces(:beta_support).crew_templates.find_by!(crew_kind: :support)

    patch workspace_crew_template_agent_profile_path(@workspace, foreign_crew, @profile), params: {
      agent_profile: attributes_for(@profile.current_version)
    }

    assert_response :not_found
  end

  private
    def attributes_for(version)
      {
        expected_version_number: version.version_number,
        instructions: version.instructions,
        allowed_tools: version.allowed_tools,
        runtime_profile_key: version.runtime_profile_key,
        fallback_profile_keys: version.fallback_profile_keys,
        timeout_seconds: version.timeout_seconds,
        max_steps: version.max_steps,
        max_tool_calls: version.max_tool_calls,
        review_policy: version.review_policy
      }
    end
end
