class CreateCrewConfigurationRecords < ActiveRecord::Migration[8.1]
  def change
    create_table :crew_templates do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }
      t.string :crew_kind, null: false
      t.string :name, null: false
      t.timestamps
    end
    add_index :crew_templates, [ :workspace_id, :id ], unique: true
    add_index :crew_templates, [ :workspace_id, :crew_kind ], unique: true
    add_check_constraint :crew_templates,
      "crew_kind IN ('support', 'customer_success')", name: "crew_templates_kind"
    add_check_constraint :crew_templates,
      "name <> '' AND length(name) <= 100", name: "crew_templates_name"

    create_table :agent_profiles do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }
      t.bigint :crew_template_id, null: false
      t.string :role_key, null: false
      t.string :name, null: false
      t.bigint :current_version_id
      t.timestamps
    end
    add_index :agent_profiles, [ :workspace_id, :id ], unique: true
    add_index :agent_profiles, [ :workspace_id, :crew_template_id, :id ], unique: true,
      name: "index_agent_profiles_on_workspace_crew_id"
    add_index :agent_profiles, [ :crew_template_id, :role_key ], unique: true
    add_foreign_key :agent_profiles, :crew_templates,
      column: [ :workspace_id, :crew_template_id ], primary_key: [ :workspace_id, :id ]
    add_check_constraint :agent_profiles,
      "role_key IN ('support_coordinator', 'support_investigator', 'resolution_drafter', " \
      "'support_reviewer', 'account_analyst', 'risk_investigator', 'success_strategist', 'success_reviewer')",
      name: "agent_profiles_role"
    add_check_constraint :agent_profiles,
      "name <> '' AND length(name) <= 100", name: "agent_profiles_name"

    create_table :agent_profile_versions do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }
      t.bigint :agent_profile_id, null: false
      t.integer :version_number, null: false
      t.text :instructions, null: false
      t.jsonb :allowed_tools, null: false, default: []
      t.string :runtime_profile_key, null: false
      t.jsonb :fallback_profile_keys, null: false, default: []
      t.integer :timeout_seconds, null: false
      t.integer :max_steps, null: false
      t.integer :max_tool_calls, null: false
      t.string :review_policy, null: false
      t.bigint :created_by_membership_id
      t.bigint :created_by_user_id
      t.timestamps
    end
    add_index :agent_profile_versions, [ :workspace_id, :id ], unique: true
    add_index :agent_profile_versions, [ :workspace_id, :agent_profile_id, :id ], unique: true,
      name: "index_agent_versions_on_workspace_profile_id"
    add_index :agent_profile_versions, [ :agent_profile_id, :version_number ], unique: true,
      name: "index_agent_versions_on_profile_and_number"
    add_foreign_key :agent_profile_versions, :agent_profiles,
      column: [ :workspace_id, :agent_profile_id ], primary_key: [ :workspace_id, :id ]
    add_foreign_key :agent_profile_versions, :memberships,
      column: [ :workspace_id, :created_by_membership_id, :created_by_user_id ],
      primary_key: [ :workspace_id, :id, :user_id ]
    add_foreign_key :agent_profile_versions, :users, column: :created_by_user_id
    add_check_constraint :agent_profile_versions,
      "version_number > 0", name: "agent_profile_versions_number"
    add_check_constraint :agent_profile_versions,
      "octet_length(instructions) BETWEEN 1 AND 8000", name: "agent_profile_versions_instructions"
    add_check_constraint :agent_profile_versions,
      "jsonb_typeof(allowed_tools) = 'array' AND jsonb_array_length(allowed_tools) <= 8 AND " \
      "allowed_tools <@ '[\"conversation_read\", \"case_read\", \"account_read\", \"knowledge_search\", " \
      "\"public_web_search\", \"draft_propose\", \"note_propose\", \"review_record\"]'::jsonb",
      name: "agent_profile_versions_tools"
    add_check_constraint :agent_profile_versions,
      "runtime_profile_key IN ('workspace_default', 'thorough', 'fast') AND " \
      "jsonb_typeof(fallback_profile_keys) = 'array' AND jsonb_array_length(fallback_profile_keys) <= 2 AND " \
      "fallback_profile_keys <@ '[\"workspace_default\", \"thorough\", \"fast\"]'::jsonb",
      name: "agent_profile_versions_runtime"
    add_check_constraint :agent_profile_versions,
      "timeout_seconds BETWEEN 30 AND 900 AND max_steps BETWEEN 1 AND 20 AND max_tool_calls BETWEEN 0 AND 50",
      name: "agent_profile_versions_budget"
    add_check_constraint :agent_profile_versions,
      "review_policy IN ('required', 'on_policy_flag')", name: "agent_profile_versions_review"
    add_check_constraint :agent_profile_versions,
      "(created_by_membership_id IS NULL AND created_by_user_id IS NULL) OR " \
      "(created_by_membership_id IS NOT NULL AND created_by_user_id IS NOT NULL)",
      name: "agent_profile_versions_actor"

    add_foreign_key :agent_profiles, :agent_profile_versions,
      column: [ :workspace_id, :id, :current_version_id ],
      primary_key: [ :workspace_id, :agent_profile_id, :id ],
      name: "fk_agent_profiles_current_version"

    install_defaults
    protect_configuration
  end

  private
    def install_defaults
      reversible do |direction|
        direction.up do
          execute <<~SQL
            INSERT INTO crew_templates (workspace_id, crew_kind, name, created_at, updated_at)
            SELECT id, definition.crew_kind, definition.name, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
            FROM workspaces
            CROSS JOIN (VALUES
              ('support', 'Support Crew'),
              ('customer_success', 'Customer Success Crew')
            ) AS definition(crew_kind, name);

            INSERT INTO agent_profiles (workspace_id, crew_template_id, role_key, name, created_at, updated_at)
            SELECT crew_templates.workspace_id, crew_templates.id, definition.role_key, definition.name,
                   CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
            FROM crew_templates
            JOIN (VALUES
              ('support', 'support_coordinator', 'Coordinator / Triage'),
              ('support', 'support_investigator', 'Investigator'),
              ('support', 'resolution_drafter', 'Resolution Drafter'),
              ('support', 'support_reviewer', 'Policy / Quality Reviewer'),
              ('customer_success', 'account_analyst', 'Account Analyst'),
              ('customer_success', 'risk_investigator', 'Risk Investigator'),
              ('customer_success', 'success_strategist', 'Success Strategist'),
              ('customer_success', 'success_reviewer', 'Policy / Quality Reviewer')
            ) AS definition(crew_kind, role_key, name)
              ON definition.crew_kind = crew_templates.crew_kind;

            INSERT INTO agent_profile_versions (
              workspace_id, agent_profile_id, version_number, instructions, allowed_tools,
              runtime_profile_key, fallback_profile_keys, timeout_seconds, max_steps,
              max_tool_calls, review_policy, created_at, updated_at
            )
            SELECT agent_profiles.workspace_id, agent_profiles.id, 1,
              CASE agent_profiles.role_key
                WHEN 'support_coordinator' THEN 'Classify the case, surface urgency and missing facts, and choose only the specialists needed.'
                WHEN 'support_investigator' THEN 'Investigate the case against current conversation facts and approved evidence. State uncertainty and do not invent facts.'
                WHEN 'resolution_drafter' THEN 'Propose a plain-language resolution grounded in cited evidence. Never send or schedule a customer message.'
                WHEN 'support_reviewer' THEN 'Check evidence, policy, stale sources, conflicts, and unsupported claims before human review.'
                WHEN 'account_analyst' THEN 'Summarise current account facts and deterministic health signals without turning inference into fact.'
                WHEN 'risk_investigator' THEN 'Investigate material risk changes, likely causes, evidence, and uncertainty within the account scope.'
                WHEN 'success_strategist' THEN 'Propose bounded, evidence-backed interventions for a human owner. Never contact a customer.'
                WHEN 'success_reviewer' THEN 'Check evidence, policy, stale sources, conflicts, and unsupported claims before human review.'
              END,
              CASE agent_profiles.role_key
                WHEN 'support_coordinator' THEN '["case_read", "conversation_read"]'::jsonb
                WHEN 'support_investigator' THEN '["case_read", "conversation_read", "knowledge_search", "public_web_search"]'::jsonb
                WHEN 'resolution_drafter' THEN '["case_read", "conversation_read", "draft_propose", "knowledge_search"]'::jsonb
                WHEN 'support_reviewer' THEN '["case_read", "conversation_read", "knowledge_search", "review_record"]'::jsonb
                WHEN 'account_analyst' THEN '["account_read", "conversation_read"]'::jsonb
                WHEN 'risk_investigator' THEN '["account_read", "conversation_read", "knowledge_search", "public_web_search"]'::jsonb
                WHEN 'success_strategist' THEN '["account_read", "knowledge_search", "note_propose"]'::jsonb
                WHEN 'success_reviewer' THEN '["account_read", "knowledge_search", "review_record"]'::jsonb
              END,
              'workspace_default', '[]'::jsonb, 300, 10, 20, 'required',
              CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
            FROM agent_profiles;

            UPDATE agent_profiles
            SET current_version_id = agent_profile_versions.id,
                updated_at = CURRENT_TIMESTAMP
            FROM agent_profile_versions
            WHERE agent_profile_versions.agent_profile_id = agent_profiles.id;
          SQL
        end
      end
    end

    def protect_configuration
      reversible do |direction|
        direction.up do
          execute <<~SQL
            CREATE FUNCTION validate_agent_profile_identity()
            RETURNS trigger LANGUAGE plpgsql AS $$
            DECLARE kind text;
            BEGIN
              SELECT crew_kind INTO kind FROM crew_templates
              WHERE id = NEW.crew_template_id AND workspace_id = NEW.workspace_id;
              IF (kind = 'support' AND NEW.role_key NOT IN (
                    'support_coordinator', 'support_investigator', 'resolution_drafter', 'support_reviewer'
                  )) OR
                 (kind = 'customer_success' AND NEW.role_key NOT IN (
                    'account_analyst', 'risk_investigator', 'success_strategist', 'success_reviewer'
                  )) OR kind IS NULL THEN
                RAISE EXCEPTION 'agent role does not belong to its crew';
              END IF;
              RETURN NEW;
            END;
            $$;
            CREATE TRIGGER agent_profiles_validate_identity
            BEFORE INSERT ON agent_profiles
            FOR EACH ROW EXECUTE FUNCTION validate_agent_profile_identity();

            CREATE FUNCTION validate_agent_profile_version()
            RETURNS trigger
            LANGUAGE plpgsql
            AS $$
            DECLARE
              role text;
              maximum_tools jsonb;
            BEGIN
              SELECT role_key INTO role FROM agent_profiles
              WHERE id = NEW.agent_profile_id AND workspace_id = NEW.workspace_id
              FOR UPDATE;
              maximum_tools := CASE role
                WHEN 'support_coordinator' THEN '["conversation_read", "case_read"]'::jsonb
                WHEN 'support_investigator' THEN '["conversation_read", "case_read", "knowledge_search", "public_web_search"]'::jsonb
                WHEN 'resolution_drafter' THEN '["conversation_read", "case_read", "knowledge_search", "draft_propose"]'::jsonb
                WHEN 'support_reviewer' THEN '["conversation_read", "case_read", "knowledge_search", "review_record"]'::jsonb
                WHEN 'account_analyst' THEN '["account_read", "conversation_read"]'::jsonb
                WHEN 'risk_investigator' THEN '["account_read", "conversation_read", "knowledge_search", "public_web_search"]'::jsonb
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

            CREATE TRIGGER agent_profile_versions_validate_policy
            BEFORE INSERT ON agent_profile_versions
            FOR EACH ROW EXECUTE FUNCTION validate_agent_profile_version();

            CREATE FUNCTION protect_agent_profile_version()
            RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
              IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
                RETURN OLD;
              END IF;
              RAISE EXCEPTION 'agent profile versions are append only';
            END;
            $$;
            CREATE TRIGGER agent_profile_versions_append_only
            BEFORE UPDATE OR DELETE ON agent_profile_versions
            FOR EACH ROW EXECUTE FUNCTION protect_agent_profile_version();
            CREATE TRIGGER agent_profile_versions_no_truncate
            BEFORE TRUNCATE ON agent_profile_versions
            FOR EACH STATEMENT EXECUTE FUNCTION protect_agent_profile_version();

            CREATE FUNCTION require_current_agent_profile_version()
            RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
              IF NOT EXISTS (
                SELECT 1 FROM agent_profiles
                WHERE id = NEW.id AND workspace_id = NEW.workspace_id AND current_version_id IS NOT NULL
              ) THEN
                RAISE EXCEPTION 'agent profile must have a current version';
              END IF;
              RETURN NULL;
            END;
            $$;
            CREATE CONSTRAINT TRIGGER agent_profiles_require_current_version
            AFTER INSERT OR UPDATE ON agent_profiles
            DEFERRABLE INITIALLY DEFERRED
            FOR EACH ROW EXECUTE FUNCTION require_current_agent_profile_version();

            CREATE FUNCTION protect_agent_profile()
            RETURNS trigger LANGUAGE plpgsql AS $$
            DECLARE old_number integer; new_number integer;
            BEGIN
              IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
                RETURN OLD;
              END IF;
              IF TG_OP = 'UPDATE' AND
                 ROW(OLD.id, OLD.workspace_id, OLD.crew_template_id, OLD.role_key, OLD.name, OLD.created_at)
                 IS NOT DISTINCT FROM
                 ROW(NEW.id, NEW.workspace_id, NEW.crew_template_id, NEW.role_key, NEW.name, NEW.created_at) AND
                 OLD.current_version_id IS DISTINCT FROM NEW.current_version_id THEN
                SELECT version_number INTO old_number FROM agent_profile_versions WHERE id = OLD.current_version_id;
                SELECT version_number INTO new_number FROM agent_profile_versions WHERE id = NEW.current_version_id;
                IF NEW.current_version_id IS NOT NULL AND (OLD.current_version_id IS NULL OR new_number > old_number) THEN
                  RETURN NEW;
                END IF;
              END IF;
              RAISE EXCEPTION 'agent profile identity and history are durable';
            END;
            $$;
            CREATE TRIGGER agent_profiles_protect_record
            BEFORE UPDATE OR DELETE ON agent_profiles
            FOR EACH ROW EXECUTE FUNCTION protect_agent_profile();
            CREATE TRIGGER agent_profiles_no_truncate
            BEFORE TRUNCATE ON agent_profiles
            FOR EACH STATEMENT EXECUTE FUNCTION protect_agent_profile();

            CREATE FUNCTION protect_crew_template()
            RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
              IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
                RETURN OLD;
              END IF;
              RAISE EXCEPTION 'crew template identity is durable';
            END;
            $$;
            CREATE TRIGGER crew_templates_protect_record
            BEFORE UPDATE OR DELETE ON crew_templates
            FOR EACH ROW EXECUTE FUNCTION protect_crew_template();
            CREATE TRIGGER crew_templates_no_truncate
            BEFORE TRUNCATE ON crew_templates
            FOR EACH STATEMENT EXECUTE FUNCTION protect_crew_template();
          SQL
        end
        direction.down do
          execute "DROP FUNCTION IF EXISTS protect_crew_template() CASCADE"
          execute "DROP FUNCTION IF EXISTS protect_agent_profile() CASCADE"
          execute "DROP FUNCTION IF EXISTS require_current_agent_profile_version() CASCADE"
          execute "DROP FUNCTION IF EXISTS protect_agent_profile_version() CASCADE"
          execute "DROP FUNCTION IF EXISTS validate_agent_profile_version() CASCADE"
          execute "DROP FUNCTION IF EXISTS validate_agent_profile_identity() CASCADE"
        end
      end
    end
end
