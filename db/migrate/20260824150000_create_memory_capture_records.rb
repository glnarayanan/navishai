class CreateMemoryCaptureRecords < ActiveRecord::Migration[8.1]
  def change
    add_column :memory_records, :capture_key, :string
    add_index :memory_records, [ :workspace_id, :capture_key ], unique: true,
      where: "capture_key IS NOT NULL"
    add_check_constraint :memory_records,
      "capture_key IS NULL OR octet_length(capture_key) BETWEEN 1 AND 200",
      name: "memory_records_capture_key"

    create_table :memory_index_entries do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }
      t.references :memory_record, null: false
      t.string :status, null: false, default: "pending"
      t.integer :attempt_count, null: false, default: 0
      t.string :external_document_id
      t.string :external_status
      t.string :failure_code
      t.datetime :last_attempted_at
      t.datetime :indexed_at
      t.timestamps
    end
    add_index :memory_index_entries, [ :workspace_id, :id ], unique: true
    add_index :memory_index_entries, [ :workspace_id, :memory_record_id ], unique: true
    add_index :memory_index_entries, [ :workspace_id, :status ]
    add_foreign_key :memory_index_entries, :memory_records,
      column: [ :workspace_id, :memory_record_id ], primary_key: [ :workspace_id, :id ], on_delete: :cascade
    add_check_constraint :memory_index_entries,
      "status IN ('pending', 'indexing', 'queued', 'indexed', 'failed', 'unknown') AND attempt_count >= 0",
      name: "memory_index_entries_state"
    add_check_constraint :memory_index_entries,
      "(status = 'pending' AND attempt_count = 0 AND external_document_id IS NULL AND external_status IS NULL AND " \
      "failure_code IS NULL AND last_attempted_at IS NULL AND indexed_at IS NULL) OR " \
      "(status = 'indexing' AND attempt_count > 0 AND last_attempted_at IS NOT NULL AND indexed_at IS NULL) OR " \
      "(status = 'queued' AND attempt_count > 0 AND external_document_id IS NOT NULL AND external_status IS NOT NULL AND " \
      "failure_code IS NULL AND last_attempted_at IS NOT NULL AND indexed_at IS NULL) OR " \
      "(status = 'indexed' AND attempt_count > 0 AND external_document_id IS NOT NULL AND external_status = 'done' AND " \
      "failure_code IS NULL AND last_attempted_at IS NOT NULL AND indexed_at IS NOT NULL) OR " \
      "(status IN ('failed', 'unknown') AND attempt_count > 0 AND failure_code IS NOT NULL AND " \
      "last_attempted_at IS NOT NULL AND indexed_at IS NULL)",
      name: "memory_index_entries_result"
    add_check_constraint :memory_index_entries,
      "external_document_id IS NULL OR octet_length(external_document_id) BETWEEN 1 AND 200",
      name: "memory_index_entries_document"
    add_check_constraint :memory_index_entries,
      "external_status IS NULL OR external_status IN ('queued', 'extracting', 'chunking', 'embedding', 'done', 'failed')",
      name: "memory_index_entries_external_status"
    add_check_constraint :memory_index_entries,
      "failure_code IS NULL OR failure_code ~ '^[a-z][a-z0-9_]{0,99}$'",
      name: "memory_index_entries_failure"

    create_table :memory_proposals do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }
      t.references :source_crew_artifact, null: false
      t.references :source_agent_profile, null: false
      t.bigint :account_id
      t.bigint :contact_id
      t.bigint :support_case_id
      t.bigint :reviewed_by_membership_id
      t.bigint :reviewed_by_user_id
      t.bigint :published_memory_record_id
      t.uuid :proposal_key, null: false, default: -> { "gen_random_uuid()" }
      t.string :memory_type, null: false
      t.string :scope_kind, null: false
      t.string :topic, null: false
      t.text :content, null: false
      t.string :content_digest, null: false
      t.decimal :confidence, precision: 4, scale: 3, null: false
      t.string :status, null: false, default: "proposed"
      t.datetime :reviewed_at
      t.timestamps
    end
    add_index :memory_proposals, :proposal_key, unique: true
    add_index :memory_proposals, [ :workspace_id, :id ], unique: true
    add_index :memory_proposals, [ :workspace_id, :source_crew_artifact_id, :content_digest ], unique: true,
      name: "index_memory_proposals_on_source_and_digest"
    add_index :memory_proposals, [ :workspace_id, :status ]
    add_foreign_key :memory_proposals, :crew_artifacts,
      column: [ :workspace_id, :source_crew_artifact_id ], primary_key: [ :workspace_id, :id ]
    add_foreign_key :memory_proposals, :agent_profiles,
      column: [ :workspace_id, :source_agent_profile_id ], primary_key: [ :workspace_id, :id ]
    add_foreign_key :memory_proposals, :accounts,
      column: [ :workspace_id, :account_id ], primary_key: [ :workspace_id, :id ]
    add_foreign_key :memory_proposals, :contacts,
      column: [ :workspace_id, :contact_id ], primary_key: [ :workspace_id, :id ]
    add_foreign_key :memory_proposals, :support_cases,
      column: [ :workspace_id, :support_case_id ], primary_key: [ :workspace_id, :id ]
    add_foreign_key :memory_proposals, :memberships,
      column: [ :workspace_id, :reviewed_by_membership_id, :reviewed_by_user_id ],
      primary_key: [ :workspace_id, :id, :user_id ]
    add_foreign_key :memory_proposals, :memory_records,
      column: [ :workspace_id, :published_memory_record_id ], primary_key: [ :workspace_id, :id ]
    add_check_constraint :memory_proposals,
      "memory_type IN ('semantic', 'profile') AND scope_kind IN ('account', 'contact', 'support_case') AND " \
      "octet_length(topic) BETWEEN 1 AND 200 AND octet_length(content) BETWEEN 1 AND 32768 AND " \
      "content_digest ~ '^[0-9a-f]{64}$' AND confidence BETWEEN 0.000 AND 1.000",
      name: "memory_proposals_content"
    add_check_constraint :memory_proposals,
      "(scope_kind = 'account' AND account_id IS NOT NULL AND contact_id IS NULL AND support_case_id IS NULL) OR " \
      "(scope_kind = 'contact' AND account_id IS NULL AND contact_id IS NOT NULL AND support_case_id IS NULL) OR " \
      "(scope_kind = 'support_case' AND account_id IS NULL AND contact_id IS NULL AND support_case_id IS NOT NULL)",
      name: "memory_proposals_scope"
    add_check_constraint :memory_proposals,
      "(status = 'proposed' AND reviewed_by_membership_id IS NULL AND reviewed_by_user_id IS NULL AND " \
      "published_memory_record_id IS NULL AND reviewed_at IS NULL) OR " \
      "(status = 'accepted' AND reviewed_by_membership_id IS NOT NULL AND reviewed_by_user_id IS NOT NULL AND " \
      "published_memory_record_id IS NOT NULL AND reviewed_at IS NOT NULL) OR " \
      "(status = 'rejected' AND reviewed_by_membership_id IS NOT NULL AND reviewed_by_user_id IS NOT NULL AND " \
      "published_memory_record_id IS NULL AND reviewed_at IS NOT NULL)",
      name: "memory_proposals_review"

    reversible do |direction|
      direction.up do
        execute <<~SQL
          CREATE FUNCTION protect_memory_index_entry()
          RETURNS trigger LANGUAGE plpgsql AS $$
          BEGIN
            IF TG_OP = 'TRUNCATE' THEN
              RAISE EXCEPTION 'memory index entries cannot be truncated';
            END IF;
            IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
              RETURN OLD;
            END IF;
            IF TG_OP = 'DELETE' OR ROW(OLD.id, OLD.workspace_id, OLD.memory_record_id, OLD.created_at)
              IS DISTINCT FROM ROW(NEW.id, NEW.workspace_id, NEW.memory_record_id, NEW.created_at) THEN
              RAISE EXCEPTION 'memory index entry identity is immutable';
            END IF;
            IF NOT ((OLD.status IN ('pending', 'queued', 'failed', 'unknown', 'indexing') AND NEW.status = 'indexing') OR
                    (OLD.status = 'indexing' AND NEW.status IN ('queued', 'indexed', 'failed', 'unknown'))) THEN
              RAISE EXCEPTION 'memory index entry transition is invalid';
            END IF;
            RETURN NEW;
          END;
          $$;
          CREATE TRIGGER memory_index_entries_protect
          BEFORE UPDATE OR DELETE ON memory_index_entries
          FOR EACH ROW EXECUTE FUNCTION protect_memory_index_entry();
          CREATE TRIGGER memory_index_entries_no_truncate
          BEFORE TRUNCATE ON memory_index_entries
          FOR EACH STATEMENT EXECUTE FUNCTION protect_memory_index_entry();

          CREATE FUNCTION protect_memory_proposal()
          RETURNS trigger LANGUAGE plpgsql AS $$
          BEGIN
            IF TG_OP = 'TRUNCATE' THEN
              RAISE EXCEPTION 'memory proposals cannot be truncated';
            END IF;
            IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
              RETURN OLD;
            END IF;
            IF TG_OP = 'DELETE' THEN
              RAISE EXCEPTION 'memory proposals cannot be deleted';
            END IF;
            IF ROW(OLD.id, OLD.workspace_id, OLD.source_crew_artifact_id, OLD.source_agent_profile_id,
              OLD.account_id, OLD.contact_id, OLD.support_case_id, OLD.proposal_key, OLD.memory_type,
              OLD.scope_kind, OLD.topic, OLD.content, OLD.content_digest, OLD.confidence, OLD.created_at)
              IS DISTINCT FROM
              ROW(NEW.id, NEW.workspace_id, NEW.source_crew_artifact_id, NEW.source_agent_profile_id,
              NEW.account_id, NEW.contact_id, NEW.support_case_id, NEW.proposal_key, NEW.memory_type,
              NEW.scope_kind, NEW.topic, NEW.content, NEW.content_digest, NEW.confidence, NEW.created_at) THEN
              RAISE EXCEPTION 'memory proposal identity is immutable';
            END IF;
            IF OLD.status <> 'proposed' OR NEW.status NOT IN ('accepted', 'rejected') THEN
              RAISE EXCEPTION 'memory proposal review is terminal';
            END IF;
            RETURN NEW;
          END;
          $$;
          CREATE TRIGGER memory_proposals_protect
          BEFORE UPDATE OR DELETE ON memory_proposals
          FOR EACH ROW EXECUTE FUNCTION protect_memory_proposal();
          CREATE TRIGGER memory_proposals_no_truncate
          BEFORE TRUNCATE ON memory_proposals
          FOR EACH STATEMENT EXECUTE FUNCTION protect_memory_proposal();
        SQL
      end
      direction.down do
        execute <<~SQL
          DROP TRIGGER IF EXISTS memory_proposals_no_truncate ON memory_proposals;
          DROP TRIGGER IF EXISTS memory_proposals_protect ON memory_proposals;
          DROP FUNCTION IF EXISTS protect_memory_proposal();
          DROP TRIGGER IF EXISTS memory_index_entries_no_truncate ON memory_index_entries;
          DROP TRIGGER IF EXISTS memory_index_entries_protect ON memory_index_entries;
          DROP FUNCTION IF EXISTS protect_memory_index_entry();
        SQL
      end
    end
  end
end
