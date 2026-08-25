class AddAuditRetentionExpiry < ActiveRecord::Migration[8.1]
  def change
    add_column :audit_events, :expired_at, :datetime
    add_index :audit_events, [ :workspace_id, :expired_at, :occurred_at ], name: "index_audit_events_for_retention"

    change_table :workspace_data_policies do |t|
      t.string :audit_expiry_status
      t.datetime :audit_expiry_cutoff_at
      t.integer :audit_expired_event_count, null: false, default: 0
      t.string :audit_expiry_failure_code
      t.datetime :audit_expiry_started_at
      t.datetime :audit_expiry_completed_at
    end
    add_check_constraint :workspace_data_policies,
      "audit_expiry_status IS NULL OR audit_expiry_status IN ('pending', 'running', 'completed', 'failed')",
      name: "workspace_data_policies_audit_expiry_status"
    add_check_constraint :workspace_data_policies,
      "audit_expired_event_count >= 0",
      name: "workspace_data_policies_audit_expiry_count"
    add_check_constraint :workspace_data_policies,
      "audit_expiry_failure_code IS NULL OR audit_expiry_failure_code ~ '^[a-z][a-z0-9_]{0,99}$'",
      name: "workspace_data_policies_audit_expiry_failure"

    reversible do |direction|
      direction.up do
        execute <<~SQL
          CREATE FUNCTION expire_workspace_audit(target_workspace_id bigint, cutoff timestamp without time zone)
          RETURNS integer
          LANGUAGE plpgsql
          SECURITY DEFINER
          SET search_path = public, pg_temp
          AS $$
          DECLARE affected integer;
          BEGIN
            IF target_workspace_id IS NULL OR cutoff IS NULL THEN
              RAISE EXCEPTION 'workspace and cutoff are required';
            END IF;
            LOCK TABLE audit_events IN ACCESS EXCLUSIVE MODE;
            ALTER TABLE audit_events DISABLE TRIGGER USER;
            UPDATE audit_events
            SET actor_id = NULL, actor_kind = 'system', metadata = '{}'::jsonb,
                request_id = NULL, ip_address = NULL, expired_at = CURRENT_TIMESTAMP
            WHERE workspace_id = target_workspace_id AND occurred_at < cutoff AND expired_at IS NULL;
            GET DIAGNOSTICS affected = ROW_COUNT;
            ALTER TABLE audit_events ENABLE TRIGGER USER;
            RETURN affected;
          END;
          $$;
          REVOKE ALL ON FUNCTION expire_workspace_audit(bigint, timestamp without time zone) FROM PUBLIC;
        SQL
      end
      direction.down { execute "DROP FUNCTION expire_workspace_audit(bigint, timestamp without time zone)" }
    end
  end
end
