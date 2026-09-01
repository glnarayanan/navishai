require "test_helper"
require Rails.root.join("db/migrate/20260901020000_add_runtime_transport_contract")

class AddRuntimeTransportContractTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "up revokes every preexisting approval and test record and audits approved installations" do
    migration = AddRuntimeTransportContract.new
    source = runtime_installations(:acme_scripted)
    owner = memberships(:owner_support)
    tested_only_key = "d" * 64
    mismatched_key = "e" * 64

    migration.migrate(:down)
    RuntimeInstallation.reset_column_information
    source.update_columns(
      approved: true, approved_by_membership_id: owner.id, approved_by_user_id: owner.user_id,
      approved_at: Time.current, runtime_test_status: "passed", runtime_test_failure_code: nil,
      runtime_tested_at: Time.current, runtime_tested_configuration_fingerprint: source.configuration_fingerprint,
      runtime_test_input_units: 12, runtime_test_output_units: 3, runtime_test_usage_observed: true
    )
    attributes = source.reload.attributes.except("id", "detection_key", "created_at", "updated_at")
    RuntimeInstallation.insert_all!([ attributes.merge(
      "detection_key" => tested_only_key, "approved" => false,
      "approved_by_membership_id" => nil, "approved_by_user_id" => nil, "approved_at" => nil
    ) ])
    RuntimeInstallation.insert_all!([ attributes.merge(
      "detection_key" => mismatched_key, "adapter_key" => "fixture_managed",
      "account_metadata" => { "authentication" => "managed_on_runner", "transport" => "managed_process" },
      "execution_mode" => "bounded", "approved" => false,
      "approved_by_membership_id" => nil, "approved_by_user_id" => nil, "approved_at" => nil
    ) ])
    previous_audit_count = AuditEvent.where(
      action: "runtime.installation_revoked", subject_type: "RuntimeInstallation", subject_id: source.id
    ).count

    migration.migrate(:up)
    RuntimeInstallation.reset_column_information

    [ source.reload, RuntimeInstallation.find_by!(detection_key: tested_only_key) ].each do |installation|
      assert_equal "built_in_https", installation.transport
      assert_not installation.approved?
      assert_nil installation.approved_by_membership_id
      assert_nil installation.approved_by_user_id
      assert_nil installation.approved_at
      assert_equal "untested", installation.runtime_test_status
      assert_nil installation.runtime_test_failure_code
      assert_nil installation.runtime_tested_at
      assert_nil installation.runtime_tested_configuration_fingerprint
      assert_equal 0, installation.runtime_test_input_units
      assert_equal 0, installation.runtime_test_output_units
      assert_not installation.runtime_test_usage_observed?
      assert_not installation.runnable?
    end
    mismatched = RuntimeInstallation.find_by!(detection_key: mismatched_key)
    assert_equal "managed_process", mismatched.transport
    assert_equal "legacy_unknown", mismatched.execution_mode
    assert_not mismatched.approved?
    assert_not mismatched.runnable?
    assert_equal 1, AuditEvent.where(
      action: "runtime.installation_revoked", subject_type: "RuntimeInstallation", subject_id: source.id
    ).count - previous_audit_count
    audit = AuditEvent.where(
      action: "runtime.installation_revoked", subject_type: "RuntimeInstallation", subject_id: source.id
    ).order(:id).last
    assert audit.system?
    assert audit.source_system?
    assert_nil audit.actor_id

    constraint = ActiveRecord::Base.connection.select_value(<<~SQL)
      SELECT pg_get_constraintdef(oid)
      FROM pg_constraint
      WHERE conname = 'runtime_installations_transport'
    SQL
    assert_includes constraint, "execution_mode"
    assert_includes constraint, "host_trusted"
    assert_includes constraint, "strong_isolated"
  ensure
    migration&.migrate(:up) unless ActiveRecord::Base.connection.column_exists?(:runtime_installations, :transport)
    RuntimeInstallation.reset_column_information
    RuntimeInstallation.where(detection_key: tested_only_key).delete_all if tested_only_key
    RuntimeInstallation.where(detection_key: mismatched_key).delete_all if mismatched_key
    source&.update_columns(
      approved: false, approved_by_membership_id: nil, approved_by_user_id: nil, approved_at: nil,
      runtime_test_status: "untested", runtime_test_failure_code: nil, runtime_tested_at: nil,
      runtime_tested_configuration_fingerprint: nil, runtime_test_input_units: 0,
      runtime_test_output_units: 0, runtime_test_usage_observed: false
    )
  end
end
