class CreatePublicWebExtractions < ActiveRecord::Migration[8.1]
  OLD_TOOLS = %w[
    conversation_read case_read account_read knowledge_search public_web_search
    draft_propose note_propose review_record
  ].freeze
  NEW_TOOLS = (OLD_TOOLS + [ "web_extract" ]).freeze

  def up
    create_table :public_web_extractions do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }
      t.references :public_web_search_result, null: false
      t.string :request_key, null: false
      t.string :status, null: false, default: "extracting"
      t.text :source_url, null: false
      t.text :final_url
      t.text :content
      t.string :content_digest
      t.string :failure_code
      t.bigint :requested_by_membership_id, null: false
      t.bigint :requested_by_user_id, null: false
      t.datetime :retrieved_at
      t.datetime :source_updated_at
      t.timestamps
    end
    add_index :public_web_extractions, [ :workspace_id, :id ], unique: true
    add_index :public_web_extractions, [ :workspace_id, :request_key ], unique: true
    add_foreign_key :public_web_extractions, :public_web_search_results,
      column: [ :workspace_id, :public_web_search_result_id ], primary_key: [ :workspace_id, :id ], on_delete: :cascade
    add_foreign_key :public_web_extractions, :memberships,
      column: [ :workspace_id, :requested_by_membership_id, :requested_by_user_id ],
      primary_key: [ :workspace_id, :id, :user_id ]
    add_foreign_key :public_web_extractions, :users, column: :requested_by_user_id
    add_check_constraint :public_web_extractions,
      "octet_length(request_key) BETWEEN 1 AND 128 AND status IN ('extracting', 'completed', 'failed') AND " \
      "octet_length(source_url) BETWEEN 9 AND 2048 AND source_url ~ '^https://'",
      name: "public_web_extractions_identity"
    add_check_constraint :public_web_extractions,
      "(status = 'extracting' AND final_url IS NULL AND content IS NULL AND content_digest IS NULL AND failure_code IS NULL AND retrieved_at IS NULL AND source_updated_at IS NULL) OR " \
      "(status = 'completed' AND octet_length(final_url) BETWEEN 9 AND 2048 AND final_url ~ '^https://' AND " \
      "octet_length(content) BETWEEN 1 AND 1048576 AND content_digest ~ '^[0-9a-f]{64}$' AND failure_code IS NULL AND retrieved_at IS NOT NULL) OR " \
      "(status = 'failed' AND final_url IS NULL AND content IS NULL AND content_digest IS NULL AND " \
      "failure_code ~ '^[a-z][a-z0-9_]{0,99}$' AND retrieved_at IS NULL AND source_updated_at IS NULL)",
      name: "public_web_extractions_result"

    execute <<~SQL
      CREATE FUNCTION protect_public_web_extraction()
      RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF TG_OP IN ('DELETE', 'TRUNCATE') THEN
          RAISE EXCEPTION 'public web extraction is append-only';
        ELSIF ROW(OLD.id, OLD.workspace_id, OLD.public_web_search_result_id, OLD.request_key, OLD.source_url,
          OLD.requested_by_membership_id, OLD.requested_by_user_id, OLD.created_at)
          IS DISTINCT FROM ROW(NEW.id, NEW.workspace_id, NEW.public_web_search_result_id, NEW.request_key, NEW.source_url,
          NEW.requested_by_membership_id, NEW.requested_by_user_id, NEW.created_at) THEN
          RAISE EXCEPTION 'public web extraction identity is immutable';
        END IF;
        IF OLD.status <> 'extracting' OR NEW.status NOT IN ('completed', 'failed') THEN
          RAISE EXCEPTION 'public web extraction result is terminal';
        END IF;
        RETURN NEW;
      END;
      $$;
      CREATE TRIGGER public_web_extractions_protect
      BEFORE UPDATE OR DELETE ON public_web_extractions
      FOR EACH ROW EXECUTE FUNCTION protect_public_web_extraction();
      CREATE TRIGGER public_web_extractions_no_truncate
      BEFORE TRUNCATE ON public_web_extractions
      FOR EACH STATEMENT EXECUTE FUNCTION protect_public_web_extraction();
    SQL
    install_tool_policy(NEW_TOOLS)
  end

  def down
    if select_value("SELECT EXISTS (SELECT 1 FROM agent_profile_versions WHERE allowed_tools ? 'web_extract')") ||
        select_value("SELECT EXISTS (SELECT 1 FROM runtime_installations WHERE allowed_tools ? 'web_extract')")
      raise ActiveRecord::IrreversibleMigration, "web_extract is present in durable policy"
    end

    install_tool_policy(OLD_TOOLS)
    execute "DROP TRIGGER IF EXISTS public_web_extractions_no_truncate ON public_web_extractions"
    execute "DROP TRIGGER IF EXISTS public_web_extractions_protect ON public_web_extractions"
    execute "DROP FUNCTION IF EXISTS protect_public_web_extraction()"
    drop_table :public_web_extractions
  end

  private
    def install_tool_policy(tools)
      quoted_tools = connection.quote(JSON.generate(tools))
      remove_check_constraint :agent_profile_versions, name: "agent_profile_versions_tools"
      add_check_constraint :agent_profile_versions,
        "jsonb_typeof(allowed_tools) = 'array' AND jsonb_array_length(allowed_tools) <= 8 AND " \
        "allowed_tools <@ #{quoted_tools}::jsonb", name: "agent_profile_versions_tools"
      remove_check_constraint :runtime_installations, name: "runtime_installations_policy_arrays"
      add_check_constraint :runtime_installations,
        "jsonb_typeof(allowed_role_keys) = 'array' AND jsonb_array_length(allowed_role_keys) <= 8 AND " \
        "jsonb_typeof(allowed_tools) = 'array' AND jsonb_array_length(allowed_tools) <= #{tools.size} AND " \
        "jsonb_typeof(allowed_data_classes) = 'array' AND jsonb_array_length(allowed_data_classes) <= 8",
        name: "runtime_installations_policy_arrays"
      install_agent_profile_function(include_extract: tools.include?("web_extract"))
      install_runtime_function(quoted_tools)
    end

    def install_agent_profile_function(include_extract:)
      investigator = %w[conversation_read case_read knowledge_search public_web_search]
      investigator << "web_extract" if include_extract
      risk = %w[account_read conversation_read knowledge_search public_web_search]
      risk << "web_extract" if include_extract
      execute <<~SQL
        CREATE OR REPLACE FUNCTION validate_agent_profile_version()
        RETURNS trigger LANGUAGE plpgsql AS $$
        DECLARE role text; maximum_tools jsonb;
        BEGIN
          SELECT role_key INTO role FROM agent_profiles
          WHERE id = NEW.agent_profile_id AND workspace_id = NEW.workspace_id FOR UPDATE;
          maximum_tools := CASE role
            WHEN 'support_coordinator' THEN '["conversation_read", "case_read"]'::jsonb
            WHEN 'support_investigator' THEN '#{JSON.generate(investigator)}'::jsonb
            WHEN 'resolution_drafter' THEN '["conversation_read", "case_read", "knowledge_search", "draft_propose"]'::jsonb
            WHEN 'support_reviewer' THEN '["conversation_read", "case_read", "knowledge_search", "review_record"]'::jsonb
            WHEN 'account_analyst' THEN '["account_read", "conversation_read"]'::jsonb
            WHEN 'risk_investigator' THEN '#{JSON.generate(risk)}'::jsonb
            WHEN 'success_strategist' THEN '["account_read", "knowledge_search", "note_propose"]'::jsonb
            WHEN 'success_reviewer' THEN '["account_read", "knowledge_search", "review_record"]'::jsonb
          END;
          IF role IS NULL OR NOT (NEW.allowed_tools <@ maximum_tools) OR
             NEW.allowed_tools <> (SELECT jsonb_agg(value ORDER BY value) FROM (
               SELECT DISTINCT value FROM jsonb_array_elements(NEW.allowed_tools)
             ) values) OR
             NEW.runtime_profile_key IN (SELECT jsonb_array_elements_text(NEW.fallback_profile_keys)) OR
             jsonb_array_length(NEW.fallback_profile_keys) <>
               (SELECT count(DISTINCT value) FROM jsonb_array_elements_text(NEW.fallback_profile_keys) values) THEN
            RAISE EXCEPTION 'agent profile exceeds its approved policy bounds';
          END IF;
          RETURN NEW;
        END;
        $$;
      SQL
    end

    def install_runtime_function(quoted_tools)
      execute <<~SQL
        CREATE OR REPLACE FUNCTION validate_runtime_installation()
        RETURNS trigger LANGUAGE plpgsql AS $$
        DECLARE metadata_key text;
        BEGIN
          IF NEW.allowed_role_keys <@ '["support_coordinator", "support_investigator", "resolution_drafter", "support_reviewer", "account_analyst", "risk_investigator", "success_strategist", "success_reviewer"]'::jsonb = false OR
             NEW.allowed_tools <@ #{quoted_tools}::jsonb = false OR
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
      SQL
    end
end
