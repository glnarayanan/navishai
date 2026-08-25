require "test_helper"

class RuntimeRouterTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:acme_support)
    @installation = approve_scripted_runtime(workspace: @workspace, membership: memberships(:owner_support))
    CrewConfiguration.install_defaults!(workspace: @workspace)
    @profile = @workspace.agent_profiles.find_by!(role_key: "support_investigator")
    current = @profile.current_version
    @version = @workspace.agent_profile_versions.create!(
      agent_profile: @profile, version_number: current.version_number + 100,
      instructions: current.instructions, allowed_tools: current.allowed_tools,
      runtime_profile_key: "thorough", fallback_profile_keys: [ "fast" ],
      timeout_seconds: current.timeout_seconds, max_steps: current.max_steps,
      max_tool_calls: current.max_tool_calls, review_policy: current.review_policy
    )
  end

  test "selects the first compatible fallback and freezes disclosure and budgets" do
    @installation.update!(profile_keys: [ "fast" ], max_input_units: 12_000, max_output_units: 3_000)

    selection = RuntimeRouter.resolve!(workspace: @workspace, profile_version: @version)

    assert_equal @installation, selection.installation
    assert_equal "fast", selection.profile_key
    assert_equal "fallback", selection.reason
    assert_includes selection.detail, "Thorough was unavailable"
    assert_includes selection.detail, "profile not assigned"
    assert_equal %w[approved_knowledge case_content customer_identity public_web_query], selection.data_classes
    assert_equal 12_000, selection.max_input_units
    assert_equal 3_000, selection.max_output_units
  end

  test "denies fallback when capability, data, or budget policy changes semantics" do
    @installation.update!(
      approved: false, approved_by_membership: nil, approved_by_user: nil, approved_at: nil,
      capabilities: [ "structured_output" ]
    )
    @installation.update!(
      approved: true, approved_by_membership: memberships(:owner_support), approved_by_user: users(:owner), approved_at: Time.current,
      profile_keys: [ "fast", "thorough" ], allowed_data_classes: [ "case_content" ], max_steps: 1
    )

    error = assert_raises(RuntimeRouter::NoCompatibleRuntime) do
      RuntimeRouter.resolve!(workspace: @workspace, profile_version: @version)
    end
    assert_includes error.message, "capability mismatch"
    assert_includes error.message, "data not allowed"
    assert_includes error.message, "step budget exceeded"
  end

  test "cannot select a runtime from another workspace" do
    foreign = runtime_installations(:acme_scripted).dup
    foreign.workspace = workspaces(:beta_support)
    foreign.detection_key = "f" * 64
    foreign.approved_by_membership = memberships(:outsider_beta)
    foreign.approved_by_user = users(:outsider)
    foreign.save!

    runtime_installations(:acme_scripted).update!(
      approved: false, approved_by_membership: nil, approved_by_user: nil, approved_at: nil
    )

    assert_raises(RuntimeRouter::NoCompatibleRuntime) do
      RuntimeRouter.resolve!(workspace: @workspace, profile_version: @version)
    end
  end
end
