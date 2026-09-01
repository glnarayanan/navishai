require "test_helper"
require Rails.root.join("db/migrate/20260901010000_add_execution_boundary_contract")

class AddExecutionBoundaryContractTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "up preserves bounded evidence and revokes ambiguous runtime evidence" do
    migration = AddExecutionBoundaryContract.new
    source = runtime_installations(:acme_scripted)
    owner = memberships(:owner_support)
    ambiguous_key = "d" * 64
    CrewConfiguration.install_defaults!(workspace: source.workspace)

    source.update_columns(
      approved: true, approved_by_membership_id: owner.id, approved_by_user_id: owner.user_id,
      approved_at: Time.current, runtime_test_status: "passed", runtime_test_failure_code: nil,
      runtime_tested_at: Time.current, runtime_tested_configuration_fingerprint: source.configuration_fingerprint,
      runtime_test_input_units: 12, runtime_test_output_units: 3, runtime_test_usage_observed: true
    )
    migration.migrate(:down)
    RuntimeInstallation.reset_column_information
    AgentProfileVersion.reset_column_information
    ExecutionRun.reset_column_information
    legacy_validation = ActiveRecord::Base.connection.select_value(
      "SELECT pg_get_functiondef('public.validate_runtime_installation()'::regprocedure)"
    )
    assert_not_includes legacy_validation, "execution_mode"

    attributes = RuntimeInstallation.find(source.id).attributes.except("id", "detection_key", "created_at", "updated_at")
    RuntimeInstallation.insert_all!([ attributes.merge(
      "detection_key" => ambiguous_key, "adapter_key" => "fixture",
      "account_metadata" => { "authentication" => "managed_on_runner" }
    ) ])

    migration.migrate(:up)
    RuntimeInstallation.reset_column_information
    AgentProfileVersion.reset_column_information
    ExecutionRun.reset_column_information
    current_validation = ActiveRecord::Base.connection.select_value(
      "SELECT pg_get_functiondef('public.validate_runtime_installation()'::regprocedure)"
    )
    assert_includes current_validation, "OLD.execution_mode"
    assert_includes current_validation, "NEW.execution_mode"

    bounded = RuntimeInstallation.find(source.id)
    ambiguous = RuntimeInstallation.find_by!(detection_key: ambiguous_key)
    assert_equal "bounded", bounded.execution_mode
    assert bounded.approved?
    assert_equal "passed", bounded.runtime_test_status
    assert_equal "legacy_unknown", ambiguous.execution_mode
    assert_not ambiguous.approved?
    assert_equal "untested", ambiguous.runtime_test_status
    assert_nil ambiguous.runtime_tested_configuration_fingerprint
    assert_equal [ "strong_isolation_required" ], AgentProfileVersion.distinct.pluck(:isolation_policy)
    if ExecutionRun.exists?
      assert_equal [ "legacy_unknown" ], ExecutionRun.distinct.pluck(:selected_execution_mode)
      assert_equal [ "legacy_unknown" ], ExecutionRun.distinct.pluck(:selected_isolation_policy)
    end
  ensure
    migration&.migrate(:up) unless ActiveRecord::Base.connection.column_exists?(:runtime_installations, :execution_mode)
    RuntimeInstallation.reset_column_information
    RuntimeInstallation.where(detection_key: ambiguous_key).delete_all if ambiguous_key
    source&.update_columns(
      approved: false, approved_by_membership_id: nil, approved_by_user_id: nil, approved_at: nil,
      runtime_test_status: "untested", runtime_test_failure_code: nil, runtime_tested_at: nil,
      runtime_tested_configuration_fingerprint: nil, runtime_test_input_units: 0,
      runtime_test_output_units: 0, runtime_test_usage_observed: false
    )
  end
end
