require "test_helper"
require Rails.root.join("db/migrate/20260831120000_add_runtime_configuration_and_test_evidence")
require Rails.root.join("db/migrate/20260831121000_require_passing_runtime_test_for_approval")
require Rails.root.join("db/migrate/20260831143000_freeze_runtime_configuration_on_execution_runs")
require Rails.root.join("db/migrate/20260901010000_add_execution_boundary_contract")
require Rails.root.join("db/migrate/20260901020000_add_runtime_transport_contract")

class RuntimeConfigurationMigrationSequenceTest < ActiveSupport::TestCase
  test "the runtime configuration migrations preserve the audit boundary in sequence" do
    source_id = runtime_installations(:acme_scripted).id
    owner = memberships(:owner_support)
    down_migrations = [
      AddRuntimeTransportContract,
      AddExecutionBoundaryContract,
      FreezeRuntimeConfigurationOnExecutionRuns,
      RequirePassingRuntimeTestForApproval,
      AddRuntimeConfigurationAndTestEvidence
    ]
    up_migrations = down_migrations.reverse

    down_migrations.each do |migration_class|
      migration_class.new.migrate(:down)
      reset_migration_models
    end

    RuntimeInstallation.find(source_id).update_columns(
      approved: true, approved_by_membership_id: owner.id, approved_by_user_id: owner.user_id,
      approved_at: Time.current
    )
    previous_audit_count = AuditEvent.where(
      action: "runtime.installation_revoked", subject_type: "RuntimeInstallation", subject_id: source_id
    ).count

    up_migrations.each do |migration_class|
      migration_class.new.migrate(:up)
      reset_migration_models
    end

    installation = RuntimeInstallation.find(source_id)
    assert_not installation.approved?
    assert_equal previous_audit_count + 1, AuditEvent.where(
      action: "runtime.installation_revoked", subject_type: "RuntimeInstallation", subject_id: source_id
    ).count
    audit = AuditEvent.where(
      action: "runtime.installation_revoked", subject_type: "RuntimeInstallation", subject_id: source_id
    ).order(:id).last
    assert audit.system?
    assert audit.source_system?
    assert_nil audit.actor_id
    assert_equal "bounded", installation.execution_mode
    assert_equal "built_in_https", installation.transport
  ensure
    ensure_latest_schema
    reset_migration_models
    RuntimeInstallation.find_by(id: source_id)&.update_columns(
      approved: false, approved_by_membership_id: nil, approved_by_user_id: nil, approved_at: nil,
      runtime_test_status: "untested", runtime_test_failure_code: nil, runtime_tested_at: nil,
      runtime_tested_configuration_fingerprint: nil, runtime_test_input_units: 0,
      runtime_test_output_units: 0, runtime_test_usage_observed: false
    ) if ActiveRecord::Base.connection.column_exists?(:runtime_installations, :transport)
  end

  private
    def reset_migration_models
      RuntimeInstallation.reset_column_information
      ExecutionRun.reset_column_information
      AgentProfileVersion.reset_column_information
    end

    def ensure_latest_schema
      connection = ActiveRecord::Base.connection
      AddRuntimeConfigurationAndTestEvidence.new.migrate(:up) unless connection.column_exists?(:runtime_installations, :configuration_fingerprint)
      RequirePassingRuntimeTestForApproval.new.migrate(:up) unless connection.check_constraints(:runtime_installations).any? { |constraint| constraint.name == "runtime_installations_approval_requires_test" }
      FreezeRuntimeConfigurationOnExecutionRuns.new.migrate(:up) unless connection.column_exists?(:execution_runs, :selected_runtime_configuration_fingerprint)
      AddExecutionBoundaryContract.new.migrate(:up) unless connection.column_exists?(:runtime_installations, :execution_mode)
      AddRuntimeTransportContract.new.migrate(:up) unless connection.column_exists?(:runtime_installations, :transport)
    end
end
