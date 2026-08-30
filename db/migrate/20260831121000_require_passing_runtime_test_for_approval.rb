class RequirePassingRuntimeTestForApproval < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      UPDATE runtime_installations
      SET approved = false,
          approved_by_membership_id = NULL,
          approved_by_user_id = NULL,
          approved_at = NULL,
          updated_at = CURRENT_TIMESTAMP
      WHERE approved = true
    SQL
    add_check_constraint :runtime_installations,
      "approved = false OR (runtime_test_status = 'passed' AND " \
      "runtime_tested_configuration_fingerprint = configuration_fingerprint)",
      name: "runtime_installations_approval_requires_test"
  end

  def down
    remove_check_constraint :runtime_installations,
      name: "runtime_installations_approval_requires_test"
  end
end
