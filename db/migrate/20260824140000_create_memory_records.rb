class CreateMemoryRecords < ActiveRecord::Migration[8.1]
  def change
    add_index :workspaces, [ :id, :organization_id ], unique: true,
      name: "index_workspaces_on_id_and_organization_id"

    create_table :memory_records do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }
      t.bigint :organization_id
      t.bigint :account_id
      t.bigint :contact_id
      t.bigint :support_case_id
      t.bigint :crew_template_id
      t.bigint :agent_profile_id
      t.bigint :user_id
      t.bigint :source_agent_profile_id
      t.bigint :source_membership_id
      t.bigint :source_user_id
      t.bigint :supersedes_memory_record_id
      t.uuid :memory_key, null: false, default: -> { "gen_random_uuid()" }
      t.string :memory_type, null: false
      t.string :scope_kind, null: false
      t.string :topic, null: false
      t.text :content, null: false
      t.string :content_digest, null: false
      t.string :authority, null: false
      t.string :origin_kind, null: false
      t.string :source_reference, null: false
      t.string :source_digest, null: false
      t.datetime :observed_at, null: false
      t.datetime :valid_from, null: false
      t.datetime :valid_until
      t.decimal :confidence, precision: 4, scale: 3, null: false
      t.string :retention_policy, null: false
      t.datetime :retention_until
      t.timestamps
    end

    add_index :memory_records, :memory_key, unique: true
    add_index :memory_records, [ :workspace_id, :id ], unique: true
    add_index :memory_records, [ :workspace_id, :memory_type, :topic ],
      name: "index_memory_records_on_workspace_type_topic"
    add_index :memory_records, [ :workspace_id, :scope_kind ]
    add_index :memory_records, [ :workspace_id, :organization_id ], where: "organization_id IS NOT NULL"
    add_index :memory_records, [ :workspace_id, :account_id ], where: "account_id IS NOT NULL"
    add_index :memory_records, [ :workspace_id, :contact_id ], where: "contact_id IS NOT NULL"
    add_index :memory_records, [ :workspace_id, :support_case_id ], where: "support_case_id IS NOT NULL"
    add_index :memory_records, [ :workspace_id, :crew_template_id ], where: "crew_template_id IS NOT NULL"
    add_index :memory_records, [ :workspace_id, :agent_profile_id ], where: "agent_profile_id IS NOT NULL"
    add_index :memory_records, [ :workspace_id, :user_id ], where: "user_id IS NOT NULL"
    add_index :memory_records, [ :workspace_id, :source_agent_profile_id ], where: "source_agent_profile_id IS NOT NULL"
    add_index :memory_records, [ :workspace_id, :source_membership_id, :source_user_id ],
      where: "source_membership_id IS NOT NULL", name: "index_memory_records_on_source_human"
    add_index :memory_records, [ :workspace_id, :supersedes_memory_record_id ],
      where: "supersedes_memory_record_id IS NOT NULL", name: "index_memory_records_on_supersedes"

    add_foreign_key :memory_records, :workspaces,
      column: [ :workspace_id, :organization_id ], primary_key: [ :id, :organization_id ],
      name: "fk_memory_records_organization_workspace"
    add_foreign_key :memory_records, :accounts,
      column: [ :workspace_id, :account_id ], primary_key: [ :workspace_id, :id ]
    add_foreign_key :memory_records, :contacts,
      column: [ :workspace_id, :contact_id ], primary_key: [ :workspace_id, :id ]
    add_foreign_key :memory_records, :support_cases,
      column: [ :workspace_id, :support_case_id ], primary_key: [ :workspace_id, :id ]
    add_foreign_key :memory_records, :crew_templates,
      column: [ :workspace_id, :crew_template_id ], primary_key: [ :workspace_id, :id ]
    add_foreign_key :memory_records, :agent_profiles,
      column: [ :workspace_id, :agent_profile_id ], primary_key: [ :workspace_id, :id ],
      name: "fk_memory_records_scope_agent"
    add_foreign_key :memory_records, :memberships,
      column: [ :workspace_id, :user_id ], primary_key: [ :workspace_id, :user_id ],
      name: "fk_memory_records_scope_user"
    add_foreign_key :memory_records, :agent_profiles,
      column: [ :workspace_id, :source_agent_profile_id ], primary_key: [ :workspace_id, :id ],
      name: "fk_memory_records_source_agent"
    add_foreign_key :memory_records, :memberships,
      column: [ :workspace_id, :source_membership_id, :source_user_id ],
      primary_key: [ :workspace_id, :id, :user_id ], name: "fk_memory_records_source_human"
    add_foreign_key :memory_records, :memory_records,
      column: [ :workspace_id, :supersedes_memory_record_id ], primary_key: [ :workspace_id, :id ],
      name: "fk_memory_records_supersedes"

    add_check_constraint :memory_records,
      "memory_type IN ('episodic', 'semantic', 'profile', 'procedural')", name: "memory_records_type"
    add_check_constraint :memory_records,
      "scope_kind IN ('organization', 'workspace', 'account', 'contact', 'support_case', 'crew', 'agent', 'user')",
      name: "memory_records_scope_kind"
    add_check_constraint :memory_records, scope_shape_check, name: "memory_records_scope_shape"
    add_check_constraint :memory_records,
      "octet_length(topic) BETWEEN 1 AND 200 AND octet_length(content) BETWEEN 1 AND 32768",
      name: "memory_records_content"
    add_check_constraint :memory_records,
      "content_digest ~ '^[0-9a-f]{64}$' AND source_digest ~ '^[0-9a-f]{64}$'",
      name: "memory_records_digests"
    add_check_constraint :memory_records,
      "octet_length(source_reference) BETWEEN 1 AND 2048", name: "memory_records_source_reference"
    add_check_constraint :memory_records,
      "authority IN ('inference', 'source_record', 'human_correction')", name: "memory_records_authority"
    add_check_constraint :memory_records,
      "origin_kind IN ('system', 'agent', 'human')", name: "memory_records_origin_kind"
    add_check_constraint :memory_records, origin_shape_check, name: "memory_records_origin_shape"
    add_check_constraint :memory_records,
      "authority <> 'human_correction' OR origin_kind = 'human'", name: "memory_records_correction_authority"
    add_check_constraint :memory_records,
      "authority <> 'inference' OR origin_kind = 'agent'", name: "memory_records_inference_authority"
    add_check_constraint :memory_records,
      "authority <> 'source_record' OR origin_kind <> 'agent'", name: "memory_records_source_authority"
    add_check_constraint :memory_records,
      "memory_type <> 'procedural' OR authority = 'human_correction'", name: "memory_records_procedural_authority"
    add_check_constraint :memory_records,
      "valid_until IS NULL OR valid_until > valid_from", name: "memory_records_valid_time"
    add_check_constraint :memory_records,
      "confidence BETWEEN 0.000 AND 1.000", name: "memory_records_confidence"
    add_check_constraint :memory_records,
      "retention_policy IN ('indefinite', 'time_bound', 'source_lifetime')", name: "memory_records_retention_policy"
    add_check_constraint :memory_records,
      "(retention_policy = 'time_bound' AND retention_until IS NOT NULL AND retention_until > observed_at) OR " \
      "(retention_policy <> 'time_bound' AND retention_until IS NULL)", name: "memory_records_retention_shape"
    add_check_constraint :memory_records,
      "supersedes_memory_record_id IS NULL OR supersedes_memory_record_id <> id", name: "memory_records_no_self_supersession"

    reversible do |direction|
      direction.up do
        execute <<~SQL
          CREATE FUNCTION protect_memory_record()
          RETURNS trigger LANGUAGE plpgsql AS $$
          DECLARE
            prior memory_records%ROWTYPE;
          BEGIN
            IF TG_OP = 'INSERT' AND NEW.supersedes_memory_record_id IS NOT NULL THEN
              SELECT * INTO prior
              FROM memory_records
              WHERE id = NEW.supersedes_memory_record_id AND workspace_id = NEW.workspace_id
              FOR SHARE;

              IF prior.id IS NULL OR
                 ROW(prior.memory_type, prior.scope_kind, prior.topic, prior.organization_id,
                     prior.account_id, prior.contact_id, prior.support_case_id, prior.crew_template_id,
                     prior.agent_profile_id, prior.user_id)
                 IS DISTINCT FROM
                 ROW(NEW.memory_type, NEW.scope_kind, NEW.topic, NEW.organization_id,
                     NEW.account_id, NEW.contact_id, NEW.support_case_id, NEW.crew_template_id,
                     NEW.agent_profile_id, NEW.user_id) THEN
                RAISE EXCEPTION 'superseding memory must keep its workspace, type, topic, and scope';
              END IF;

              IF (CASE NEW.authority WHEN 'human_correction' THEN 3 WHEN 'source_record' THEN 2 ELSE 1 END) <
                 (CASE prior.authority WHEN 'human_correction' THEN 3 WHEN 'source_record' THEN 2 ELSE 1 END) THEN
                RAISE EXCEPTION 'superseding memory cannot lower authority';
              END IF;
            END IF;

            IF TG_OP = 'INSERT' AND NEW.authority = 'human_correction' AND NOT EXISTS (
              SELECT 1 FROM memberships
              WHERE id = NEW.source_membership_id AND workspace_id = NEW.workspace_id AND
                    user_id = NEW.source_user_id AND role IN ('owner', 'admin', 'manager')
            ) THEN
              RAISE EXCEPTION 'human correction requires an authorized workspace member';
            END IF;

            IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
              RETURN OLD;
            END IF;
            IF TG_OP <> 'INSERT' THEN
              RAISE EXCEPTION 'memory records are append only';
            END IF;
            RETURN NEW;
          END;
          $$;
          CREATE TRIGGER memory_records_contract
          BEFORE INSERT OR UPDATE OR DELETE ON memory_records
          FOR EACH ROW EXECUTE FUNCTION protect_memory_record();
          CREATE TRIGGER memory_records_no_truncate
          BEFORE TRUNCATE ON memory_records
          FOR EACH STATEMENT EXECUTE FUNCTION protect_memory_record();
        SQL
      end
      direction.down do
        execute <<~SQL
          DROP TRIGGER memory_records_no_truncate ON memory_records;
          DROP TRIGGER memory_records_contract ON memory_records;
          DROP FUNCTION protect_memory_record();
        SQL
      end
    end
  end

  private
    def scope_shape_check
      <<~SQL.squish
        (scope_kind = 'organization' AND organization_id IS NOT NULL AND account_id IS NULL AND contact_id IS NULL AND
          support_case_id IS NULL AND crew_template_id IS NULL AND agent_profile_id IS NULL AND user_id IS NULL) OR
        (scope_kind = 'workspace' AND organization_id IS NULL AND account_id IS NULL AND contact_id IS NULL AND
          support_case_id IS NULL AND crew_template_id IS NULL AND agent_profile_id IS NULL AND user_id IS NULL) OR
        (scope_kind = 'account' AND organization_id IS NULL AND account_id IS NOT NULL AND contact_id IS NULL AND
          support_case_id IS NULL AND crew_template_id IS NULL AND agent_profile_id IS NULL AND user_id IS NULL) OR
        (scope_kind = 'contact' AND organization_id IS NULL AND account_id IS NULL AND contact_id IS NOT NULL AND
          support_case_id IS NULL AND crew_template_id IS NULL AND agent_profile_id IS NULL AND user_id IS NULL) OR
        (scope_kind = 'support_case' AND organization_id IS NULL AND account_id IS NULL AND contact_id IS NULL AND
          support_case_id IS NOT NULL AND crew_template_id IS NULL AND agent_profile_id IS NULL AND user_id IS NULL) OR
        (scope_kind = 'crew' AND organization_id IS NULL AND account_id IS NULL AND contact_id IS NULL AND
          support_case_id IS NULL AND crew_template_id IS NOT NULL AND agent_profile_id IS NULL AND user_id IS NULL) OR
        (scope_kind = 'agent' AND organization_id IS NULL AND account_id IS NULL AND contact_id IS NULL AND
          support_case_id IS NULL AND crew_template_id IS NULL AND agent_profile_id IS NOT NULL AND user_id IS NULL) OR
        (scope_kind = 'user' AND organization_id IS NULL AND account_id IS NULL AND contact_id IS NULL AND
          support_case_id IS NULL AND crew_template_id IS NULL AND agent_profile_id IS NULL AND user_id IS NOT NULL)
      SQL
    end

    def origin_shape_check
      <<~SQL.squish
        (origin_kind = 'system' AND source_agent_profile_id IS NULL AND source_membership_id IS NULL AND source_user_id IS NULL) OR
        (origin_kind = 'agent' AND source_agent_profile_id IS NOT NULL AND source_membership_id IS NULL AND source_user_id IS NULL) OR
        (origin_kind = 'human' AND source_agent_profile_id IS NULL AND source_membership_id IS NOT NULL AND source_user_id IS NOT NULL)
      SQL
    end
end
