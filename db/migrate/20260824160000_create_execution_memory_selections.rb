class CreateExecutionMemorySelections < ActiveRecord::Migration[8.1]
  OLD_DATA_CLASSES = %w[case_content customer_identity account_context approved_knowledge public_web_query].freeze
  NEW_DATA_CLASSES = (OLD_DATA_CLASSES + [ "retrieved_memory" ]).freeze

  def up
    create_table :execution_memory_selections do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }
      t.references :execution_run, null: false
      t.references :memory_record, null: false
      t.integer :rank, null: false
      t.decimal :relevance_score, precision: 6, scale: 5, null: false
      t.timestamps
    end
    add_index :execution_memory_selections, [ :workspace_id, :id ], unique: true
    add_index :execution_memory_selections, [ :execution_run_id, :rank ], unique: true
    add_index :execution_memory_selections, [ :execution_run_id, :memory_record_id ], unique: true,
      name: "index_execution_memory_selections_on_run_and_memory"
    add_foreign_key :execution_memory_selections, :execution_runs,
      column: [ :workspace_id, :execution_run_id ], primary_key: [ :workspace_id, :id ], on_delete: :cascade
    add_foreign_key :execution_memory_selections, :memory_records,
      column: [ :workspace_id, :memory_record_id ], primary_key: [ :workspace_id, :id ]
    add_check_constraint :execution_memory_selections,
      "rank BETWEEN 1 AND 8 AND relevance_score BETWEEN 0.00000 AND 1.00000",
      name: "execution_memory_selections_bounds"
    execute <<~SQL
      CREATE FUNCTION protect_execution_memory_selection()
      RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
          RETURN OLD;
        END IF;
        RAISE EXCEPTION 'execution memory selections are append only';
      END;
      $$;
      CREATE TRIGGER execution_memory_selections_append_only
      BEFORE UPDATE OR DELETE ON execution_memory_selections
      FOR EACH ROW EXECUTE FUNCTION protect_execution_memory_selection();
      CREATE TRIGGER execution_memory_selections_no_truncate
      BEFORE TRUNCATE ON execution_memory_selections
      FOR EACH STATEMENT EXECUTE FUNCTION protect_execution_memory_selection();
    SQL
    replace_execution_run_policy(NEW_DATA_CLASSES)
    install_runtime_policy(NEW_DATA_CLASSES)
  end

  def down
    if select_value(<<~SQL)
      SELECT EXISTS (SELECT 1 FROM runtime_installations WHERE allowed_data_classes ? 'retrieved_memory') OR
             EXISTS (SELECT 1 FROM execution_runs WHERE disclosed_data_classes ? 'retrieved_memory')
    SQL
      raise ActiveRecord::IrreversibleMigration, "retrieved_memory is present in durable runtime or run policy"
    end

    install_runtime_policy(OLD_DATA_CLASSES)
    replace_execution_run_policy(OLD_DATA_CLASSES)
    execute "DROP TRIGGER execution_memory_selections_no_truncate ON execution_memory_selections"
    execute "DROP TRIGGER execution_memory_selections_append_only ON execution_memory_selections"
    execute "DROP FUNCTION protect_execution_memory_selection()"
    drop_table :execution_memory_selections
  end

  private
    def replace_execution_run_policy(data_classes)
      remove_check_constraint :execution_runs, name: "execution_runs_disclosure_budgets"
      add_check_constraint :execution_runs,
        "jsonb_typeof(disclosed_data_classes) = 'array' AND jsonb_array_length(disclosed_data_classes) <= 8 AND " \
        "disclosed_data_classes <@ #{connection.quote(JSON.generate(data_classes))}::jsonb AND " \
        "max_input_units BETWEEN 1 AND 10000000 AND max_output_units BETWEEN 1 AND 10000000",
        name: "execution_runs_disclosure_budgets"
    end

    def install_runtime_policy(data_classes)
      quoted = connection.quote(JSON.generate(data_classes))
      execute <<~SQL
        CREATE OR REPLACE FUNCTION validate_runtime_installation()
        RETURNS trigger LANGUAGE plpgsql AS $$
        DECLARE metadata_key text;
        BEGIN
          IF NEW.allowed_role_keys <@ '["support_coordinator", "support_investigator", "resolution_drafter", "support_reviewer", "account_analyst", "risk_investigator", "success_strategist", "success_reviewer"]'::jsonb = false OR
             NEW.allowed_tools <@ '["conversation_read", "case_read", "account_read", "knowledge_search", "public_web_search", "draft_propose", "note_propose", "review_record", "web_extract"]'::jsonb = false OR
             NEW.allowed_data_classes <@ #{quoted}::jsonb = false OR
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
      SQL
    end
end
