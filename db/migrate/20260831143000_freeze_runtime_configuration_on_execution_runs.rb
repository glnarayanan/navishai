class FreezeRuntimeConfigurationOnExecutionRuns < ActiveRecord::Migration[8.1]
  def up
    add_column :execution_runs, :selected_runtime_configuration_fingerprint, :string
    add_column :execution_runs, :selected_effective_model, :string
    execute <<~SQL
      UPDATE execution_runs
      SET selected_runtime_configuration_fingerprint = '#{"0" * 64}',
          selected_effective_model = 'legacy_unknown'
      WHERE selected_runtime_configuration_fingerprint IS NULL
         OR selected_effective_model IS NULL
    SQL
    change_column_default :execution_runs, :selected_runtime_configuration_fingerprint, "0" * 64
    change_column_default :execution_runs, :selected_effective_model, "legacy_unknown"
    change_column_null :execution_runs, :selected_runtime_configuration_fingerprint, false
    change_column_null :execution_runs, :selected_effective_model, false
    add_check_constraint :execution_runs,
      "selected_runtime_configuration_fingerprint ~ '^[0-9a-f]{64}$' AND " \
      "octet_length(selected_effective_model) BETWEEN 1 AND 200 AND " \
      "selected_effective_model !~ '[\\r\\n]'",
      name: "execution_runs_runtime_configuration_snapshot"

    execute <<~SQL
      CREATE OR REPLACE FUNCTION protect_execution_routing_snapshot()
      RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF ROW(OLD.runtime_installation_id, OLD.selected_runtime_detection_key, OLD.selected_adapter_key,
               OLD.selected_runtime_profile_key, OLD.selected_runtime_configuration_fingerprint,
               OLD.selected_effective_model, OLD.runtime_selection_reason, OLD.runtime_selection_detail,
               OLD.disclosed_data_classes, OLD.max_input_units, OLD.max_output_units)
           IS DISTINCT FROM
           ROW(NEW.runtime_installation_id, NEW.selected_runtime_detection_key, NEW.selected_adapter_key,
               NEW.selected_runtime_profile_key, NEW.selected_runtime_configuration_fingerprint,
               NEW.selected_effective_model, NEW.runtime_selection_reason, NEW.runtime_selection_detail,
               NEW.disclosed_data_classes, NEW.max_input_units, NEW.max_output_units) THEN
          RAISE EXCEPTION 'execution routing snapshot is durable';
        END IF;
        RETURN NEW;
      END;
      $$;
    SQL
  end

  def down
    execute <<~SQL
      CREATE OR REPLACE FUNCTION protect_execution_routing_snapshot()
      RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF ROW(OLD.runtime_installation_id, OLD.selected_runtime_detection_key, OLD.selected_adapter_key,
               OLD.selected_runtime_profile_key, OLD.runtime_selection_reason, OLD.runtime_selection_detail,
               OLD.disclosed_data_classes, OLD.max_input_units, OLD.max_output_units)
           IS DISTINCT FROM
           ROW(NEW.runtime_installation_id, NEW.selected_runtime_detection_key, NEW.selected_adapter_key,
               NEW.selected_runtime_profile_key, NEW.runtime_selection_reason, NEW.runtime_selection_detail,
               NEW.disclosed_data_classes, NEW.max_input_units, NEW.max_output_units) THEN
          RAISE EXCEPTION 'execution routing snapshot is durable';
        END IF;
        RETURN NEW;
      END;
      $$;
    SQL
    remove_check_constraint :execution_runs, name: "execution_runs_runtime_configuration_snapshot"
    remove_column :execution_runs, :selected_effective_model
    remove_column :execution_runs, :selected_runtime_configuration_fingerprint
  end
end
