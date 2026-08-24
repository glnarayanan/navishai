class CreateRuntimeInstallations < ActiveRecord::Migration[8.1]
  def change
    create_table :runtime_installations do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }
      t.string :detection_key, null: false
      t.string :adapter_key, null: false
      t.string :protocol_version, null: false
      t.text :executable_path, null: false
      t.string :executable_version, null: false
      t.jsonb :account_metadata, null: false, default: {}
      t.jsonb :capabilities, null: false, default: []
      t.string :minimum_version, null: false, default: ""
      t.string :maximum_version, null: false, default: ""
      t.string :compatibility_status, null: false
      t.text :incompatibility_reason, null: false, default: ""
      t.string :health_status, null: false
      t.datetime :checked_at, null: false
      t.boolean :approved, null: false, default: false
      t.jsonb :allowed_role_keys, null: false, default: []
      t.jsonb :allowed_tools, null: false, default: []
      t.jsonb :allowed_data_classes, null: false, default: []
      t.integer :max_timeout_seconds, null: false, default: 300
      t.integer :max_steps, null: false, default: 10
      t.integer :max_tool_calls, null: false, default: 20
      t.bigint :approved_by_membership_id
      t.bigint :approved_by_user_id
      t.datetime :approved_at
      t.timestamps
    end

    add_index :runtime_installations, [ :workspace_id, :id ], unique: true
    add_index :runtime_installations, [ :workspace_id, :detection_key ], unique: true
    add_foreign_key :runtime_installations, :memberships,
      column: [ :workspace_id, :approved_by_membership_id, :approved_by_user_id ],
      primary_key: [ :workspace_id, :id, :user_id ]
    add_foreign_key :runtime_installations, :users, column: :approved_by_user_id
    add_check_constraint :runtime_installations,
      "detection_key ~ '^[0-9a-f]{64}$' AND adapter_key ~ '^[a-z][a-z0-9_]{0,63}$' AND " \
      "protocol_version ~ '^v[1-9][0-9]*$'", name: "runtime_installations_identity"
    add_check_constraint :runtime_installations,
      "executable_path LIKE '/%' AND octet_length(executable_path) <= 4096 AND " \
      "executable_version <> '' AND octet_length(executable_version) <= 8192",
      name: "runtime_installations_executable"
    add_check_constraint :runtime_installations,
      "jsonb_typeof(account_metadata) = 'object' AND jsonb_typeof(capabilities) = 'array' AND " \
      "octet_length(account_metadata::text) <= 8192 AND jsonb_array_length(capabilities) <= 32 AND " \
      "octet_length(minimum_version) <= 100 AND octet_length(maximum_version) <= 100 AND " \
      "octet_length(incompatibility_reason) <= 1000", name: "runtime_installations_detection_metadata"
    add_check_constraint :runtime_installations,
      "compatibility_status IN ('compatible', 'warning', 'incompatible', 'unknown') AND " \
      "health_status IN ('available', 'unhealthy', 'missing')", name: "runtime_installations_status"
    add_check_constraint :runtime_installations,
      "jsonb_typeof(allowed_role_keys) = 'array' AND jsonb_array_length(allowed_role_keys) <= 8 AND " \
      "jsonb_typeof(allowed_tools) = 'array' AND jsonb_array_length(allowed_tools) <= 8 AND " \
      "jsonb_typeof(allowed_data_classes) = 'array' AND jsonb_array_length(allowed_data_classes) <= 8",
      name: "runtime_installations_policy_arrays"
    add_check_constraint :runtime_installations,
      "max_timeout_seconds BETWEEN 30 AND 900 AND max_steps BETWEEN 1 AND 20 AND max_tool_calls BETWEEN 0 AND 50",
      name: "runtime_installations_budgets"
    add_check_constraint :runtime_installations,
      "(approved = false AND approved_by_membership_id IS NULL AND approved_by_user_id IS NULL AND approved_at IS NULL) OR " \
      "(approved = true AND approved_by_membership_id IS NOT NULL AND approved_by_user_id IS NOT NULL AND approved_at IS NOT NULL)",
      name: "runtime_installations_approval"

    protect_runtime_policy
  end

  private
    def protect_runtime_policy
      reversible do |direction|
        direction.up do
          execute <<~SQL
            CREATE FUNCTION validate_runtime_installation()
            RETURNS trigger LANGUAGE plpgsql AS $$
            DECLARE metadata_key text;
            BEGIN
              IF NEW.allowed_role_keys <@ '["support_coordinator", "support_investigator", "resolution_drafter", "support_reviewer", "account_analyst", "risk_investigator", "success_strategist", "success_reviewer"]'::jsonb = false OR
                 NEW.allowed_tools <@ '["conversation_read", "case_read", "account_read", "knowledge_search", "public_web_search", "draft_propose", "note_propose", "review_record"]'::jsonb = false OR
                 NEW.allowed_data_classes <@ '["case_content", "customer_identity", "account_context", "approved_knowledge", "public_web_query"]'::jsonb = false OR
                 NEW.allowed_role_keys <> COALESCE((SELECT jsonb_agg(value ORDER BY value) FROM (SELECT DISTINCT value FROM jsonb_array_elements(NEW.allowed_role_keys)) values), '[]'::jsonb) OR
                 NEW.allowed_tools <> COALESCE((SELECT jsonb_agg(value ORDER BY value) FROM (SELECT DISTINCT value FROM jsonb_array_elements(NEW.allowed_tools)) values), '[]'::jsonb) OR
                 NEW.allowed_data_classes <> COALESCE((SELECT jsonb_agg(value ORDER BY value) FROM (SELECT DISTINCT value FROM jsonb_array_elements(NEW.allowed_data_classes)) values), '[]'::jsonb) OR
                 NEW.capabilities <> COALESCE((SELECT jsonb_agg(value ORDER BY value) FROM (SELECT DISTINCT value FROM jsonb_array_elements(NEW.capabilities)) values), '[]'::jsonb) THEN
                RAISE EXCEPTION 'runtime policy values must be bounded, sorted, and distinct';
              END IF;
              FOR metadata_key IN SELECT jsonb_object_keys(NEW.account_metadata) LOOP
                IF metadata_key ~* '(passw|secret|token|credential|cookie|authorization|private|session)' THEN
                  RAISE EXCEPTION 'runtime account metadata cannot contain secret fields';
                END IF;
              END LOOP;
              IF NEW.approved AND (NEW.health_status <> 'available' OR NEW.compatibility_status = 'incompatible') THEN
                RAISE EXCEPTION 'unavailable or incompatible runtimes cannot be approved';
              END IF;
              IF TG_OP = 'UPDATE' AND OLD.approved AND NEW.approved AND
                 ROW(OLD.adapter_key, OLD.protocol_version, OLD.executable_path, OLD.executable_version,
                     OLD.account_metadata, OLD.capabilities, OLD.minimum_version, OLD.maximum_version,
                     OLD.compatibility_status) IS DISTINCT FROM
                 ROW(NEW.adapter_key, NEW.protocol_version, NEW.executable_path, NEW.executable_version,
                     NEW.account_metadata, NEW.capabilities, NEW.minimum_version, NEW.maximum_version,
                     NEW.compatibility_status) THEN
                RAISE EXCEPTION 'runtime detection changed without revoking approval';
              END IF;
              RETURN NEW;
            END;
            $$;
            CREATE TRIGGER runtime_installations_validate_policy
            BEFORE INSERT OR UPDATE ON runtime_installations
            FOR EACH ROW EXECUTE FUNCTION validate_runtime_installation();
          SQL
        end
        direction.down do
          execute <<~SQL
            DROP TRIGGER IF EXISTS runtime_installations_validate_policy ON runtime_installations;
            DROP FUNCTION IF EXISTS validate_runtime_installation();
          SQL
        end
      end
    end
end
