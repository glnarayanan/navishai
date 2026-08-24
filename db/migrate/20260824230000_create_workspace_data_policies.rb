class CreateWorkspaceDataPolicies < ActiveRecord::Migration[8.1]
  def change
    create_table :workspace_data_policies do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.integer :content_retention_days
      t.integer :audit_retention_days
      t.timestamps
    end

    add_check_constraint :workspace_data_policies,
      "content_retention_days IS NULL OR content_retention_days IN (30, 90, 180, 365, 730, 1825)",
      name: "workspace_data_policies_content_retention"
    add_check_constraint :workspace_data_policies,
      "audit_retention_days IS NULL OR audit_retention_days IN (365, 730, 1825, 2555, 3650)",
      name: "workspace_data_policies_audit_retention"
    add_check_constraint :workspace_data_policies,
      "audit_retention_days IS NULL OR content_retention_days IS NULL OR audit_retention_days >= content_retention_days",
      name: "workspace_data_policies_audit_covers_content"

    reversible do |direction|
      direction.up do
        execute <<~SQL.squish
          INSERT INTO workspace_data_policies (workspace_id, created_at, updated_at)
          SELECT id, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP FROM workspaces
        SQL
      end
    end
  end
end
