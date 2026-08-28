class CreateOperationalChecks < ActiveRecord::Migration[8.1]
  def up
    create_table :operational_checks do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }
      t.string :check_kind, null: false
      t.string :result, null: false
      t.string :result_code, null: false
      t.string :evidence_digest, null: false
      t.string :source_commit, null: false
      t.string :archive_format
      t.bigint :table_count
      t.bigint :record_count
      t.bigint :attachment_count
      t.bigint :memory_count
      t.bigint :recorded_by_membership_id
      t.bigint :recorded_by_user_id
      t.datetime :checked_at, null: false
      t.timestamps
    end

    add_index :operational_checks, [ :workspace_id, :check_kind, :checked_at, :id ],
      name: "index_operational_checks_for_cockpit"
    add_index :operational_checks, [ :workspace_id, :id ], unique: true,
      name: "index_operational_checks_on_workspace_id_and_id"
    add_foreign_key :operational_checks, :memberships,
      column: [ :workspace_id, :recorded_by_membership_id, :recorded_by_user_id ],
      primary_key: [ :workspace_id, :id, :user_id ], name: "fk_operational_checks_actor"

    add_check_constraint :operational_checks,
      "check_kind IN ('archive_verification', 'backup_verification', 'restore_rehearsal', 'upgrade_preflight')",
      name: "operational_checks_kind"
    add_check_constraint :operational_checks,
      "result IN ('passed', 'failed', 'unavailable')",
      name: "operational_checks_result"
    add_check_constraint :operational_checks,
      "result_code ~ '^[a-z][a-z0-9_]{0,99}$'",
      name: "operational_checks_result_code"
    add_check_constraint :operational_checks,
      "evidence_digest ~ '^[0-9a-f]{64}$' AND source_commit ~ '^[0-9a-f]{40}$'",
      name: "operational_checks_digests"
    add_check_constraint :operational_checks,
      "archive_format IS NULL OR octet_length(archive_format) BETWEEN 1 AND 100",
      name: "operational_checks_archive_format"
    add_check_constraint :operational_checks,
      "(recorded_by_membership_id IS NULL) = (recorded_by_user_id IS NULL)",
      name: "operational_checks_actor"
    add_check_constraint :operational_checks,
      "(table_count IS NULL OR table_count >= 0) AND (record_count IS NULL OR record_count >= 0) AND " \
      "(attachment_count IS NULL OR attachment_count >= 0) AND (memory_count IS NULL OR memory_count >= 0)",
      name: "operational_checks_counts"

    execute <<~SQL
      CREATE FUNCTION protect_operational_check()
      RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF TG_OP = 'TRUNCATE' THEN
          RAISE EXCEPTION 'operational checks cannot be truncated';
        END IF;
        IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
          RETURN OLD;
        END IF;
        RAISE EXCEPTION 'operational checks are append only';
      END;
      $$;
      CREATE TRIGGER operational_checks_append_only
        BEFORE UPDATE OR DELETE ON operational_checks
        FOR EACH ROW EXECUTE FUNCTION protect_operational_check();
      CREATE TRIGGER operational_checks_no_truncate
        BEFORE TRUNCATE ON operational_checks
        FOR EACH STATEMENT EXECUTE FUNCTION protect_operational_check();
    SQL
  end

  def down
    drop_table :operational_checks
    execute "DROP FUNCTION IF EXISTS protect_operational_check() CASCADE"
  end
end
