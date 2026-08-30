require "test_helper"
require Rails.root.join("db/migrate/20260831121000_require_passing_runtime_test_for_approval")

class RequirePassingRuntimeTestForApprovalTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "up revokes existing approvals before adding the passing-test constraint" do
    migration = RequirePassingRuntimeTestForApproval.new
    installation = runtime_installations(:acme_scripted)
    owner = memberships(:owner_support)

    migration.migrate(:down)
    installation.update_columns(
      approved: true, approved_by_membership_id: owner.id, approved_by_user_id: owner.user_id,
      approved_at: Time.current
    )

    migration.migrate(:up)

    installation.reload
    assert_not installation.approved?
    assert_nil installation.approved_by_membership_id
    assert_nil installation.approved_by_user_id
    assert_nil installation.approved_at
    assert constraint_present?

    assert_raises(ActiveRecord::StatementInvalid) do
      installation.update_columns(
        approved: true, approved_by_membership_id: owner.id, approved_by_user_id: owner.user_id,
        approved_at: Time.current
      )
    end
    installation.reload.update_columns(
      runtime_test_status: "passed", runtime_test_failure_code: nil, runtime_tested_at: Time.current,
      runtime_tested_configuration_fingerprint: installation.configuration_fingerprint,
      approved: true, approved_by_membership_id: owner.id, approved_by_user_id: owner.user_id,
      approved_at: Time.current
    )
    assert installation.reload.approved?
  ensure
    installation&.update_columns(
      approved: false, approved_by_membership_id: nil, approved_by_user_id: nil, approved_at: nil,
      runtime_test_status: "untested", runtime_test_failure_code: nil, runtime_tested_at: nil,
      runtime_tested_configuration_fingerprint: nil, runtime_test_input_units: 0,
      runtime_test_output_units: 0, runtime_test_usage_observed: false
    )
    migration&.migrate(:up) unless constraint_present?
  end

  private
    def constraint_present?
      ActiveRecord::Base.connection.check_constraints(:runtime_installations)
        .any? { |constraint| constraint.name == "runtime_installations_approval_requires_test" }
    end
end
