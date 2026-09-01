class AddRuntimeTransportContract < ActiveRecord::Migration[8.1]
  def up
    add_column :runtime_installations, :transport, :string, null: false, default: "legacy_unknown"

    execute <<~SQL
      UPDATE runtime_installations
      SET transport = CASE
        WHEN adapter_key = 'scripted' OR COALESCE(account_metadata ->> 'transport', '') = 'built_in_https'
          THEN 'built_in_https'
        WHEN COALESCE(account_metadata ->> 'transport', '') = 'managed_process'
          THEN 'managed_process'
        ELSE 'legacy_unknown'
      END
    SQL
    execute <<~SQL
      INSERT INTO audit_events (
        workspace_id, actor_id, actor_kind, source, action, subject_type, subject_id,
        metadata, occurred_at, created_at
      )
      SELECT workspace_id, NULL, 'system', 'system', 'runtime.installation_revoked',
             'RuntimeInstallation', id, '{}'::jsonb, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM runtime_installations
      WHERE approved = true
    SQL
    execute <<~SQL
      UPDATE runtime_installations
      SET execution_mode = CASE
            WHEN transport = 'built_in_https' AND execution_mode <> 'bounded' THEN 'legacy_unknown'
            WHEN transport = 'managed_process' AND execution_mode NOT IN ('host_trusted', 'strong_isolated') THEN 'legacy_unknown'
            ELSE execution_mode
          END,
          approved = false,
          approved_by_membership_id = NULL,
          approved_by_user_id = NULL,
          approved_at = NULL,
          runtime_test_status = 'untested',
          runtime_test_failure_code = NULL,
          runtime_tested_at = NULL,
          runtime_tested_configuration_fingerprint = NULL,
          runtime_test_input_units = 0,
          runtime_test_output_units = 0,
          runtime_test_usage_observed = false,
          updated_at = CURRENT_TIMESTAMP
    SQL

    add_check_constraint :runtime_installations,
      "transport IN ('built_in_https', 'managed_process', 'legacy_unknown') AND " \
      "(transport = 'legacy_unknown' OR execution_mode = 'legacy_unknown' OR " \
      "(transport = 'built_in_https' AND execution_mode = 'bounded') OR " \
      "(transport = 'managed_process' AND execution_mode IN ('host_trusted', 'strong_isolated'))) AND " \
      "(transport <> 'legacy_unknown' OR approved = false) AND " \
      "(execution_mode <> 'legacy_unknown' OR approved = false)",
      name: "runtime_installations_transport"
    replace_runtime_installation_validation_trigger(include_transport: true)
  end

  def down
    replace_runtime_installation_validation_trigger(include_transport: false)
    execute "ALTER TABLE runtime_installations DROP CONSTRAINT IF EXISTS runtime_installations_transport"
    remove_column :runtime_installations, :transport
  end

  private
    def replace_runtime_installation_validation_trigger(include_transport:)
      old_identity = %w[
        OLD.adapter_key OLD.protocol_version OLD.executable_path OLD.executable_version
        OLD.account_metadata OLD.capabilities OLD.minimum_version OLD.maximum_version
        OLD.compatibility_status OLD.execution_mode
      ]
      new_identity = old_identity.map { |field| field.sub("OLD.", "NEW.") }
      if include_transport
        old_identity << "OLD.transport"
        new_identity << "NEW.transport"
      end

      execute <<~SQL
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
end
