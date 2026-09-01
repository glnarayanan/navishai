require "test_helper"

class ExecutionBoundaryTest < ActiveSupport::TestCase
  setup do
    @installation = runtime_installations(:acme_scripted)
    @owner = memberships(:owner_support)
  end

  test "a mode change revokes approval and clears current test evidence" do
    approve_scripted_runtime(workspace: @installation.workspace, membership: @owner)
    assert @installation.reload.approved?
    assert_equal "passed", @installation.runtime_test_status

    @installation.update!(transport: "managed_process", execution_mode: "strong_isolated")

    @installation.reload
    assert_not @installation.approved?
    assert_equal "managed_process", @installation.transport
    assert_equal "strong_isolated", @installation.execution_mode
    assert_nil @installation.approved_by_membership_id
    assert_nil @installation.approved_by_user_id
    assert_nil @installation.approved_at
    assert_equal "untested", @installation.runtime_test_status
    assert_nil @installation.runtime_tested_configuration_fingerprint
    assert_not @installation.runnable?
  end

  test "the database rejects a bypassing approved mode change with current test evidence" do
    approve_scripted_runtime(workspace: @installation.workspace, membership: @owner)
    original_fingerprint = @installation.reload.runtime_tested_configuration_fingerprint

    assert_raises(ActiveRecord::StatementInvalid) do
      RuntimeInstallation.transaction(requires_new: true) do
        @installation.update_columns(execution_mode: "host_trusted")
      end
    end

    @installation.reload
    assert_equal "bounded", @installation.execution_mode
    assert @installation.approved?
    assert_equal "passed", @installation.runtime_test_status
    assert_equal original_fingerprint, @installation.runtime_tested_configuration_fingerprint
  end

  test "the model rejects impossible known transport and execution mode pairs" do
    @installation.assign_attributes(transport: "managed_process", execution_mode: "bounded")

    assert_not @installation.valid?
    assert_includes @installation.errors[:execution_mode], "is incompatible with runtime transport"
  end

  test "the database rejects impossible transport and execution mode writes" do
    attributes = @installation.attributes.except("id", "detection_key", "created_at", "updated_at")

    assert_raises(ActiveRecord::StatementInvalid) do
      RuntimeInstallation.transaction(requires_new: true) do
        RuntimeInstallation.insert_all!([ attributes.merge(
          "detection_key" => "c" * 64, "transport" => "managed_process", "execution_mode" => "bounded"
        ) ])
      end
    end

    assert_raises(ActiveRecord::StatementInvalid) do
      RuntimeInstallation.transaction(requires_new: true) do
        @installation.update_columns(transport: "managed_process", execution_mode: "bounded")
      end
    end

    assert_equal "built_in_https", @installation.reload.transport
    assert_equal "bounded", @installation.execution_mode
  end

  test "the database rejects approving an installation with unknown transport" do
    tested_at = Time.current
    @installation.update_columns(
      transport: "legacy_unknown", approved: false, approved_by_membership_id: nil,
      approved_by_user_id: nil, approved_at: nil, runtime_test_status: "passed",
      runtime_test_failure_code: nil, runtime_tested_at: tested_at,
      runtime_tested_configuration_fingerprint: @installation.configuration_fingerprint
    )

    assert_raises(ActiveRecord::StatementInvalid) do
      RuntimeInstallation.transaction(requires_new: true) do
        @installation.update_columns(
          approved: true, approved_by_membership_id: @owner.id, approved_by_user_id: @owner.user_id,
          approved_at: tested_at
        )
      end
    end

    @installation.reload
    assert_not @installation.approved?
    assert_equal "legacy_unknown", @installation.transport
    assert_not @installation.runnable?
  end

  test "legacy runtimes cannot be approved or run" do
    @installation.update_columns(execution_mode: "legacy_unknown")
    @installation.reload

    assert_not @installation.runnable?
    @installation.assign_attributes(
      approved: true, approved_by_membership: @owner, approved_by_user: @owner.user, approved_at: Time.current,
      runtime_test_status: "passed", runtime_tested_at: Time.current,
      runtime_tested_configuration_fingerprint: @installation.configuration_fingerprint
    )

    assert_not @installation.valid?
    assert_includes @installation.errors[:approved], "cannot be approved until execution mode is known"

    @installation.update_columns(execution_mode: "bounded", transport: "legacy_unknown")
    @installation.assign_attributes(
      approved: true, approved_by_membership: @owner, approved_by_user: @owner.user, approved_at: Time.current,
      runtime_test_status: "passed", runtime_tested_at: Time.current,
      runtime_tested_configuration_fingerprint: @installation.configuration_fingerprint
    )

    assert_not @installation.valid?
    assert_includes @installation.errors[:approved], "cannot be approved until runtime transport is known"
  end

  test "new profile versions default to the conservative isolation policy" do
    CrewConfiguration.install_defaults!(workspace: @installation.workspace)
    profile = @installation.workspace.agent_profiles.find_by!(role_key: "support_investigator")
    current = profile.current_version
    version = @installation.workspace.agent_profile_versions.create!(
      agent_profile: profile, version_number: current.version_number + 100,
      instructions: current.instructions, allowed_tools: current.allowed_tools,
      runtime_profile_key: current.runtime_profile_key, fallback_profile_keys: current.fallback_profile_keys,
      timeout_seconds: current.timeout_seconds, max_steps: current.max_steps,
      max_tool_calls: current.max_tool_calls, review_policy: current.review_policy
    )

    assert_equal "strong_isolation_required", version.isolation_policy
    assert AgentPolicy.execution_mode_allowed?(version.isolation_policy, "bounded")
    assert_not AgentPolicy.execution_mode_allowed?(version.isolation_policy, "host_trusted")
  end
end
