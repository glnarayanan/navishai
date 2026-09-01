class RequirePassingRuntimeTestForApproval < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      INSERT INTO audit_events (
        workspace_id, actor_id, actor_kind, source, action, subject_type, subject_id,
        metadata, occurred_at, created_at
      )
      SELECT workspace_id, NULL, 'system', 'system', 'runtime.installation_revoked',
             'RuntimeInstallation', id, '{}'::jsonb, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM runtime_installations
      WHERE approved = true
    SQL
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
