class AddExecutionBoundaryContract < ActiveRecord::Migration[8.1]
  def up
    add_column :runtime_installations, :execution_mode, :string, null: false, default: "legacy_unknown"
    add_column :agent_profile_versions, :isolation_policy, :string, null: false,
      default: "strong_isolation_required"
    add_column :execution_runs, :selected_execution_mode, :string, null: false, default: "legacy_unknown"
    add_column :execution_runs, :selected_isolation_policy, :string, null: false, default: "legacy_unknown"

    execute <<~SQL
      UPDATE runtime_installations
      SET execution_mode = CASE
        WHEN adapter_key = 'scripted' OR COALESCE(account_metadata ->> 'transport', '') = 'built_in_https'
          THEN 'bounded'
        ELSE 'legacy_unknown'
      END
    SQL
    execute <<~SQL
      UPDATE runtime_installations
      SET approved = false,
          approved_by_membership_id = NULL,
          approved_by_user_id = NULL,
          approved_at = NULL,
          runtime_test_status = 'untested',
          runtime_test_failure_code = NULL,
          runtime_tested_at = NULL,
          runtime_tested_configuration_fingerprint = NULL,
          runtime_test_input_units = 0,
          runtime_test_output_units = 0,
          runtime_test_usage_observed = false
      WHERE execution_mode = 'legacy_unknown'
    SQL
    execute <<~SQL
      UPDATE execution_runs
      SET selected_execution_mode = 'legacy_unknown',
          selected_isolation_policy = 'legacy_unknown'
    SQL

    add_check_constraint :runtime_installations,
      "execution_mode IN ('bounded', 'host_trusted', 'strong_isolated', 'legacy_unknown') AND " \
      "(execution_mode <> 'legacy_unknown' OR approved = false)",
      name: "runtime_installations_execution_boundary"
    add_check_constraint :agent_profile_versions,
      "isolation_policy IN ('strong_isolation_required', 'host_trusted_allowed')",
      name: "agent_profile_versions_isolation_policy"
    add_check_constraint :execution_runs,
      "selected_execution_mode IN ('bounded', 'host_trusted', 'strong_isolated', 'legacy_unknown') AND " \
      "selected_isolation_policy IN ('strong_isolation_required', 'host_trusted_allowed', 'legacy_unknown') AND " \
      "((selected_execution_mode = 'legacy_unknown' AND selected_isolation_policy = 'legacy_unknown') OR " \
      "(selected_execution_mode IN ('bounded', 'strong_isolated') AND " \
      "selected_isolation_policy IN ('strong_isolation_required', 'host_trusted_allowed')) OR " \
      "(selected_execution_mode = 'host_trusted' AND selected_isolation_policy = 'host_trusted_allowed'))",
      name: "execution_runs_execution_boundary"

    replace_runtime_installation_validation_trigger
    replace_routing_snapshot_trigger
    replace_execution_run_trigger("OLD.status IN ('admitted', 'running')")
  end

  def down
    restore_runtime_installation_validation_trigger
    replace_execution_run_trigger("OLD.status = 'running'")
    restore_routing_snapshot_trigger
    remove_check_constraint :execution_runs, name: "execution_runs_execution_boundary"
    remove_check_constraint :agent_profile_versions, name: "agent_profile_versions_isolation_policy"
    remove_check_constraint :runtime_installations, name: "runtime_installations_execution_boundary"
    remove_column :execution_runs, :selected_isolation_policy
    remove_column :execution_runs, :selected_execution_mode
    remove_column :agent_profile_versions, :isolation_policy
    remove_column :runtime_installations, :execution_mode
  end

  private
    def replace_runtime_installation_validation_trigger
      execute runtime_installation_validation_function_sql(include_execution_mode: true)
    end

    def restore_runtime_installation_validation_trigger
      execute runtime_installation_validation_function_sql(include_execution_mode: false)
    end

    def runtime_installation_validation_function_sql(include_execution_mode:)
      old_identity = %w[
        OLD.adapter_key OLD.protocol_version OLD.executable_path OLD.executable_version
        OLD.account_metadata OLD.capabilities OLD.minimum_version OLD.maximum_version
        OLD.compatibility_status
      ]
      new_identity = old_identity.map { |field| field.sub("OLD.", "NEW.") }
      if include_execution_mode
        old_identity << "OLD.execution_mode"
        new_identity << "NEW.execution_mode"
      end

      <<~SQL
        CREATE OR REPLACE FUNCTION validate_runtime_installation()
        RETURNS trigger LANGUAGE plpgsql AS $$
        DECLARE metadata_key text;
        BEGIN
          IF NEW.allowed_role_keys <@ '["support_coordinator", "support_investigator", "resolution_drafter", "support_reviewer", "account_analyst", "risk_investigator", "success_strategist", "success_reviewer"]'::jsonb = false OR
             NEW.allowed_tools <@ '["conversation_read", "case_read", "account_read", "knowledge_search", "public_web_search", "draft_propose", "note_propose", "review_record", "web_extract"]'::jsonb = false OR
             NEW.allowed_data_classes <@ '["case_content","customer_identity","account_context","approved_knowledge","public_web_query","retrieved_memory"]'::jsonb = false OR
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
             ROW(#{old_identity.join(", ")}) IS DISTINCT FROM
             ROW(#{new_identity.join(", ")}) THEN
            RAISE EXCEPTION 'runtime detection changed without revoking approval';
          END IF;
          RETURN NEW;
        END;
        $$;
      SQL
    end

    def replace_routing_snapshot_trigger
      execute <<~SQL
        CREATE OR REPLACE FUNCTION protect_execution_routing_snapshot()
        RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF ROW(OLD.runtime_installation_id, OLD.selected_runtime_detection_key, OLD.selected_adapter_key,
                 OLD.selected_runtime_profile_key, OLD.selected_runtime_configuration_fingerprint,
                 OLD.selected_effective_model, OLD.selected_execution_mode, OLD.selected_isolation_policy,
                 OLD.runtime_selection_reason, OLD.runtime_selection_detail, OLD.disclosed_data_classes,
                 OLD.max_input_units, OLD.max_output_units)
             IS DISTINCT FROM
             ROW(NEW.runtime_installation_id, NEW.selected_runtime_detection_key, NEW.selected_adapter_key,
                 NEW.selected_runtime_profile_key, NEW.selected_runtime_configuration_fingerprint,
                 NEW.selected_effective_model, NEW.selected_execution_mode, NEW.selected_isolation_policy,
                 NEW.runtime_selection_reason, NEW.runtime_selection_detail, NEW.disclosed_data_classes,
                 NEW.max_input_units, NEW.max_output_units) THEN
            RAISE EXCEPTION 'execution routing snapshot is durable';
          END IF;
          RETURN NEW;
        END;
        $$;
      SQL
    end

    def restore_routing_snapshot_trigger
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

    def replace_execution_run_trigger(policy_transition)
      execute execution_run_trigger_sql(policy_transition)
    end

    def execution_run_trigger_sql(policy_transition)
      <<~SQL
        CREATE OR REPLACE FUNCTION protect_execution_run()
        RETURNS trigger LANGUAGE plpgsql AS $$
        DECLARE event_row execution_events%ROWTYPE;
        BEGIN
          IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
            RETURN OLD;
          END IF;
          IF TG_OP <> 'UPDATE' OR
             ROW(OLD.id, OLD.workspace_id, OLD.crew_task_id, OLD.agent_profile_id,
                 OLD.agent_profile_version_id, OLD.run_key, OLD.request_key, OLD.attempt_number,
                 OLD.runtime_profile_key, OLD.created_at)
               IS DISTINCT FROM
             ROW(NEW.id, NEW.workspace_id, NEW.crew_task_id, NEW.agent_profile_id,
                 NEW.agent_profile_version_id, NEW.run_key, NEW.request_key, NEW.attempt_number,
                 NEW.runtime_profile_key, NEW.created_at) THEN
            RAISE EXCEPTION 'execution run identity is durable';
          END IF;

          IF NEW.current_sequence = OLD.current_sequence AND NEW.current_event_id IS NOT DISTINCT FROM OLD.current_event_id THEN
            IF OLD.status <> 'admitting' OR NEW.status <> OLD.status OR
               ROW(OLD.input_units, OLD.output_units, OLD.output, OLD.failure_code, OLD.retryable,
                   OLD.admitted_at, OLD.started_at, OLD.finished_at)
                 IS DISTINCT FROM
               ROW(NEW.input_units, NEW.output_units, NEW.output, NEW.failure_code, NEW.retryable,
                   NEW.admitted_at, NEW.started_at, NEW.finished_at) OR
               NEW.admission_attempt_count < OLD.admission_attempt_count OR
               NEW.admission_attempt_count > OLD.admission_attempt_count + 1 THEN
              RAISE EXCEPTION 'execution admission update is invalid';
            END IF;
            RETURN NEW;
          END IF;

          IF NEW.current_sequence <> OLD.current_sequence + 1 OR NEW.current_event_id IS NULL THEN
            RAISE EXCEPTION 'execution run events must be ordered';
          END IF;
          SELECT * INTO event_row FROM execution_events WHERE id = NEW.current_event_id FOR UPDATE;
          IF event_row.id IS NULL OR event_row.workspace_id <> NEW.workspace_id OR
             event_row.execution_run_id <> NEW.id OR event_row.sequence_number <> NEW.current_sequence THEN
            RAISE EXCEPTION 'execution run event does not match';
          END IF;
          IF NEW.admission_attempt_count <> OLD.admission_attempt_count OR
             NEW.admission_attempted_at IS DISTINCT FROM OLD.admission_attempted_at OR
             (event_row.event_type <> 'run.admitted' AND NEW.last_admission_error IS DISTINCT FROM OLD.last_admission_error) OR
             (event_row.event_type = 'run.admitted' AND NEW.last_admission_error IS NOT NULL) OR
             (OLD.current_event_id IS NOT NULL AND event_row.occurred_at <
               (SELECT occurred_at FROM execution_events WHERE id = OLD.current_event_id)) THEN
            RAISE EXCEPTION 'execution event changed admission history or time order';
          END IF;
          IF (CASE event_row.event_type
            WHEN 'run.admitted' THEN OLD.status = 'admitting' AND NEW.status = 'admitted'
              AND NEW.admitted_at = event_row.occurred_at AND OLD.admitted_at IS NULL
              AND event_row.data->>'workspace_key' = (SELECT runner_key::text FROM workspaces WHERE id = NEW.workspace_id)
              AND event_row.data->>'task_key' = (SELECT task_key::text FROM crew_tasks WHERE id = NEW.crew_task_id)
              AND (event_row.data->>'attempt')::integer = NEW.attempt_number
              AND ROW(NEW.input_units, NEW.output_units, NEW.output, NEW.failure_code, NEW.retryable,
                      NEW.started_at, NEW.finished_at)
                IS NOT DISTINCT FROM
                  ROW(OLD.input_units, OLD.output_units, OLD.output, OLD.failure_code, OLD.retryable,
                      OLD.started_at, OLD.finished_at)
            WHEN 'run.started' THEN OLD.status = 'admitted' AND NEW.status = 'running'
              AND NEW.started_at = event_row.occurred_at AND OLD.started_at IS NULL
              AND octet_length(event_row.data->>'adapter') BETWEEN 1 AND 64
              AND octet_length(event_row.data->>'scenario') BETWEEN 1 AND 100
              AND (event_row.data->>'attempt')::integer = NEW.attempt_number
              AND ROW(NEW.input_units, NEW.output_units, NEW.output, NEW.failure_code, NEW.retryable,
                      NEW.admitted_at, NEW.finished_at)
                IS NOT DISTINCT FROM
                  ROW(OLD.input_units, OLD.output_units, OLD.output, OLD.failure_code, OLD.retryable,
                      OLD.admitted_at, OLD.finished_at)
            WHEN 'tool.completed' THEN OLD.status = 'running' AND NEW.status = OLD.status
              AND octet_length(event_row.data->>'tool') BETWEEN 1 AND 64
              AND octet_length(event_row.data->>'result') BETWEEN 1 AND 100
              AND ROW(NEW.input_units, NEW.output_units, NEW.output, NEW.failure_code, NEW.retryable,
                      NEW.admitted_at, NEW.started_at, NEW.finished_at)
                IS NOT DISTINCT FROM
                  ROW(OLD.input_units, OLD.output_units, OLD.output, OLD.failure_code, OLD.retryable,
                      OLD.admitted_at, OLD.started_at, OLD.finished_at)
            WHEN 'output.produced' THEN OLD.status = 'running' AND NEW.status = OLD.status
              AND NEW.output = event_row.data->>'text'
              AND ROW(NEW.input_units, NEW.output_units, NEW.failure_code, NEW.retryable,
                      NEW.admitted_at, NEW.started_at, NEW.finished_at)
                IS NOT DISTINCT FROM
                  ROW(OLD.input_units, OLD.output_units, OLD.failure_code, OLD.retryable,
                      OLD.admitted_at, OLD.started_at, OLD.finished_at)
            WHEN 'usage.observed' THEN OLD.status = 'running' AND NEW.status = OLD.status
              AND NEW.input_units = OLD.input_units + (event_row.data->>'input_units')::bigint
              AND NEW.output_units = OLD.output_units + (event_row.data->>'output_units')::bigint
              AND ROW(NEW.output, NEW.failure_code, NEW.retryable, NEW.admitted_at, NEW.started_at, NEW.finished_at)
                IS NOT DISTINCT FROM
                  ROW(OLD.output, OLD.failure_code, OLD.retryable, OLD.admitted_at, OLD.started_at, OLD.finished_at)
            WHEN 'run.completed' THEN OLD.status = 'running' AND NEW.status = 'completed'
              AND NEW.finished_at = event_row.occurred_at AND event_row.data->>'outcome' = 'completed'
              AND ROW(NEW.input_units, NEW.output_units, NEW.output, NEW.failure_code, NEW.retryable,
                      NEW.admitted_at, NEW.started_at)
                IS NOT DISTINCT FROM
                  ROW(OLD.input_units, OLD.output_units, OLD.output, OLD.failure_code, OLD.retryable,
                      OLD.admitted_at, OLD.started_at)
            WHEN 'run.failed' THEN OLD.status = 'running' AND NEW.status = 'failed'
              AND NEW.failure_code = event_row.data->>'code'
              AND NEW.retryable = (event_row.data->>'retryable')::boolean AND NEW.finished_at = event_row.occurred_at
              AND ROW(NEW.input_units, NEW.output_units, NEW.output, NEW.admitted_at, NEW.started_at)
                IS NOT DISTINCT FROM ROW(OLD.input_units, OLD.output_units, OLD.output, OLD.admitted_at, OLD.started_at)
            WHEN 'run.timed_out' THEN OLD.status = 'running' AND NEW.status = 'timed_out'
              AND NEW.failure_code = 'timed_out' AND NEW.retryable = false AND NEW.finished_at = event_row.occurred_at
              AND octet_length(event_row.data->>'reason') BETWEEN 1 AND 500
              AND ROW(NEW.input_units, NEW.output_units, NEW.output, NEW.admitted_at, NEW.started_at)
                IS NOT DISTINCT FROM ROW(OLD.input_units, OLD.output_units, OLD.output, OLD.admitted_at, OLD.started_at)
            WHEN 'run.canceled' THEN OLD.status = 'running' AND NEW.status = 'canceled'
              AND NEW.failure_code = 'canceled' AND NEW.retryable = false AND NEW.finished_at = event_row.occurred_at
              AND octet_length(event_row.data->>'reason') BETWEEN 1 AND 500
              AND ROW(NEW.input_units, NEW.output_units, NEW.output, NEW.admitted_at, NEW.started_at)
                IS NOT DISTINCT FROM ROW(OLD.input_units, OLD.output_units, OLD.output, OLD.admitted_at, OLD.started_at)
            WHEN 'run.policy_denied' THEN #{policy_transition} AND NEW.status = 'policy_denied'
              AND NEW.failure_code = event_row.data->>'code' AND NEW.retryable = false AND NEW.finished_at = event_row.occurred_at
              AND octet_length(event_row.data->>'code') BETWEEN 1 AND 100
              AND octet_length(event_row.data->>'tool') BETWEEN 1 AND 64
              AND ROW(NEW.input_units, NEW.output_units, NEW.output, NEW.admitted_at, NEW.started_at)
                IS NOT DISTINCT FROM ROW(OLD.input_units, OLD.output_units, OLD.output, OLD.admitted_at, OLD.started_at)
            ELSE false
          END) IS NOT TRUE THEN
            RAISE EXCEPTION 'invalid execution run transition';
          END IF;
          RETURN NEW;
        END;
        $$;
      SQL
    end
end
