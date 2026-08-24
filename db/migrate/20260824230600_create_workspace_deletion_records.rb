class CreateWorkspaceDeletionRecords < ActiveRecord::Migration[8.1]
  def change
    add_column :workspaces, :deletion_requested_at, :datetime
    add_index :workspaces, :deletion_requested_at

    create_table :workspace_deletion_requests do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.references :requested_by, null: false, foreign_key: { to_table: :users }
      t.string :status, null: false, default: "pending"
      t.integer :attempt_count, null: false, default: 0
      t.string :failure_code
      t.datetime :started_at
      t.datetime :completed_at
      t.timestamps
    end
    add_check_constraint :workspace_deletion_requests,
      "status IN ('pending', 'running', 'failed')", name: "workspace_deletion_requests_status"
    add_check_constraint :workspace_deletion_requests,
      "attempt_count >= 0", name: "workspace_deletion_requests_attempts"
    add_check_constraint :workspace_deletion_requests,
      "failure_code IS NULL OR failure_code ~ '^[a-z][a-z0-9_]{0,99}$'",
      name: "workspace_deletion_requests_failure"

    create_table :workspace_tombstones do |t|
      t.bigint :former_workspace_id, null: false
      t.references :organization, null: false, foreign_key: true
      t.references :deleted_by, null: false, foreign_key: { to_table: :users }
      t.string :workspace_slug, null: false
      t.datetime :requested_at, null: false
      t.datetime :deleted_at, null: false
      t.integer :record_count, null: false
      t.integer :attachment_count, null: false
      t.integer :memory_count, null: false
      t.timestamps
    end
    add_index :workspace_tombstones, :former_workspace_id, unique: true
    add_check_constraint :workspace_tombstones,
      "record_count >= 0 AND attachment_count >= 0 AND memory_count >= 0",
      name: "workspace_tombstones_counts"

    reversible do |direction|
      direction.up do
        execute <<~SQL
          CREATE FUNCTION protect_workspace_tombstone()
          RETURNS trigger LANGUAGE plpgsql AS $$
          BEGIN
            IF TG_OP = 'TRUNCATE' THEN
              RAISE EXCEPTION 'workspace tombstones cannot be truncated';
            END IF;
            RAISE EXCEPTION 'workspace tombstones are immutable';
          END;
          $$;

          CREATE TRIGGER workspace_tombstones_protect
          BEFORE UPDATE OR DELETE ON workspace_tombstones
          FOR EACH ROW EXECUTE FUNCTION protect_workspace_tombstone();
          CREATE TRIGGER workspace_tombstones_no_truncate
          BEFORE TRUNCATE ON workspace_tombstones
          FOR EACH STATEMENT EXECUTE FUNCTION protect_workspace_tombstone();
        SQL
      end
      direction.down do
        execute <<~SQL
          DROP TRIGGER workspace_tombstones_no_truncate ON workspace_tombstones;
          DROP TRIGGER workspace_tombstones_protect ON workspace_tombstones;
          DROP FUNCTION protect_workspace_tombstone();
        SQL
      end
    end
  end
end
