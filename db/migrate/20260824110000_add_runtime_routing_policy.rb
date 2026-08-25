class AddRuntimeRoutingPolicy < ActiveRecord::Migration[8.1]
  def change
    add_column :runtime_installations, :profile_keys, :jsonb, null: false, default: [ "workspace_default" ]
    add_column :runtime_installations, :max_input_units, :bigint, null: false, default: 100_000
    add_column :runtime_installations, :max_output_units, :bigint, null: false, default: 25_000
    add_check_constraint :runtime_installations,
      "jsonb_typeof(profile_keys) = 'array' AND jsonb_array_length(profile_keys) BETWEEN 1 AND 3 AND " \
      "profile_keys <@ '[\"workspace_default\", \"thorough\", \"fast\"]'::jsonb",
      name: "runtime_installations_profiles"
    add_check_constraint :runtime_installations,
      "max_input_units BETWEEN 1 AND 10000000 AND max_output_units BETWEEN 1 AND 10000000",
      name: "runtime_installations_unit_budgets"

    add_reference :execution_runs, :runtime_installation
    add_column :execution_runs, :selected_runtime_detection_key, :string, null: false, default: "0" * 64
    add_column :execution_runs, :selected_adapter_key, :string, null: false, default: "scripted"
    add_column :execution_runs, :selected_runtime_profile_key, :string, null: false, default: "workspace_default"
    add_column :execution_runs, :runtime_selection_reason, :string, null: false, default: "primary"
    add_column :execution_runs, :runtime_selection_detail, :string, null: false, default: "Primary profile selected."
    add_column :execution_runs, :disclosed_data_classes, :jsonb, null: false, default: []
    add_column :execution_runs, :max_input_units, :bigint, null: false, default: 100_000
    add_column :execution_runs, :max_output_units, :bigint, null: false, default: 25_000
    reversible do |direction|
      direction.up do
        execute "UPDATE execution_runs SET selected_runtime_profile_key = runtime_profile_key"
      end
    end
    add_check_constraint :execution_runs,
      "selected_runtime_detection_key ~ '^[0-9a-f]{64}$' AND selected_adapter_key ~ '^[a-z][a-z0-9_]{0,63}$' AND " \
      "selected_runtime_profile_key IN ('workspace_default', 'thorough', 'fast') AND " \
      "runtime_selection_reason IN ('primary', 'fallback')",
      name: "execution_runs_runtime_selection"
    add_check_constraint :execution_runs,
      "octet_length(runtime_selection_detail) BETWEEN 1 AND 500",
      name: "execution_runs_runtime_selection_detail"
    add_check_constraint :execution_runs,
      "jsonb_typeof(disclosed_data_classes) = 'array' AND jsonb_array_length(disclosed_data_classes) <= 8 AND " \
      "disclosed_data_classes <@ '[\"case_content\", \"customer_identity\", \"account_context\", \"approved_knowledge\", \"public_web_query\"]'::jsonb AND " \
      "max_input_units BETWEEN 1 AND 10000000 AND max_output_units BETWEEN 1 AND 10000000",
      name: "execution_runs_disclosure_budgets"
    add_foreign_key :execution_runs, :runtime_installations,
      column: [ :workspace_id, :runtime_installation_id ], primary_key: [ :workspace_id, :id ],
      name: "fk_execution_runs_workspace_runtime"

    reversible do |direction|
      direction.up do
        execute <<~SQL
          CREATE FUNCTION validate_runtime_routing_policy()
          RETURNS trigger LANGUAGE plpgsql AS $$
          BEGIN
            IF NEW.profile_keys <> COALESCE((
              SELECT jsonb_agg(value ORDER BY value)
              FROM (SELECT DISTINCT value FROM jsonb_array_elements(NEW.profile_keys)) values
            ), '[]'::jsonb) THEN
              RAISE EXCEPTION 'runtime profile keys must be sorted and distinct';
            END IF;
            RETURN NEW;
          END;
          $$;
          CREATE TRIGGER runtime_installations_validate_routing
          BEFORE INSERT OR UPDATE ON runtime_installations
          FOR EACH ROW EXECUTE FUNCTION validate_runtime_routing_policy();

          CREATE FUNCTION protect_execution_routing_snapshot()
          RETURNS trigger LANGUAGE plpgsql AS $$
          BEGIN
            IF ROW(OLD.runtime_installation_id, OLD.selected_runtime_detection_key, OLD.selected_adapter_key, OLD.selected_runtime_profile_key,
                   OLD.runtime_selection_reason, OLD.runtime_selection_detail, OLD.disclosed_data_classes, OLD.max_input_units, OLD.max_output_units)
               IS DISTINCT FROM
               ROW(NEW.runtime_installation_id, NEW.selected_runtime_detection_key, NEW.selected_adapter_key, NEW.selected_runtime_profile_key,
                   NEW.runtime_selection_reason, NEW.runtime_selection_detail, NEW.disclosed_data_classes, NEW.max_input_units, NEW.max_output_units) THEN
              RAISE EXCEPTION 'execution routing snapshot is durable';
            END IF;
            RETURN NEW;
          END;
          $$;
          CREATE TRIGGER execution_runs_protect_routing
          BEFORE UPDATE ON execution_runs
          FOR EACH ROW EXECUTE FUNCTION protect_execution_routing_snapshot();
        SQL
      end
      direction.down do
        execute "DROP TRIGGER IF EXISTS execution_runs_protect_routing ON execution_runs"
        execute "DROP FUNCTION IF EXISTS protect_execution_routing_snapshot()"
        execute "DROP TRIGGER IF EXISTS runtime_installations_validate_routing ON runtime_installations"
        execute "DROP FUNCTION IF EXISTS validate_runtime_routing_policy()"
      end
    end
  end
end
