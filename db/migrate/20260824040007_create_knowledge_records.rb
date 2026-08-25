class CreateKnowledgeRecords < ActiveRecord::Migration[8.1]
  def change
    create_table :knowledge_sources do |t|
      t.references :workspace, null: false, foreign_key: true
      t.string :source_kind, null: false
      t.string :source_key, null: false
      t.string :title, null: false
      t.string :canonical_url
      t.string :external_id
      t.bigint :current_version_id
      t.datetime :deleted_at
      t.bigint :deleted_by_membership_id
      t.bigint :deleted_by_user_id
      t.timestamps
    end
    add_index :knowledge_sources, [ :workspace_id, :id ], unique: true
    add_index :knowledge_sources, :source_key, unique: true
    add_index :knowledge_sources, [ :workspace_id, :source_kind, :canonical_url ], unique: true,
      where: "canonical_url IS NOT NULL", name: "index_knowledge_sources_on_workspace_kind_url"
    add_index :knowledge_sources, [ :workspace_id, :source_kind, :external_id ], unique: true,
      where: "external_id IS NOT NULL", name: "index_knowledge_sources_on_workspace_kind_external"
    add_foreign_key :knowledge_sources, :memberships,
      column: [ :workspace_id, :deleted_by_membership_id, :deleted_by_user_id ],
      primary_key: [ :workspace_id, :id, :user_id ]
    add_foreign_key :knowledge_sources, :users, column: :deleted_by_user_id
    add_check_constraint :knowledge_sources,
      "source_kind IN ('manual', 'url', 'upload', 'intercom_help_center')",
      name: "knowledge_sources_kind"
    add_check_constraint :knowledge_sources,
      "source_key ~ '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'",
      name: "knowledge_sources_key"
    add_check_constraint :knowledge_sources,
      "(source_kind = 'url' AND canonical_url ~ '^https://' AND external_id IS NULL) OR " \
      "(source_kind = 'intercom_help_center' AND external_id IS NOT NULL AND canonical_url IS NULL) OR " \
      "(source_kind IN ('manual', 'upload') AND canonical_url IS NULL AND external_id IS NULL)",
      name: "knowledge_sources_locator"
    add_check_constraint :knowledge_sources,
      "title <> '' AND length(title) <= 200 AND " \
      "(canonical_url IS NULL OR length(canonical_url) <= 2048) AND " \
      "(external_id IS NULL OR (external_id <> '' AND length(external_id) <= 500))",
      name: "knowledge_sources_identity"
    add_check_constraint :knowledge_sources,
      "(deleted_at IS NULL AND deleted_by_membership_id IS NULL AND deleted_by_user_id IS NULL) OR " \
      "(deleted_at IS NOT NULL AND deleted_by_membership_id IS NOT NULL AND deleted_by_user_id IS NOT NULL)",
      name: "knowledge_sources_deletion"

    create_table :knowledge_source_versions do |t|
      t.references :workspace, null: false, foreign_key: true
      t.bigint :knowledge_source_id, null: false
      t.bigint :stored_attachment_id
      t.integer :version_number, null: false
      t.text :content, null: false
      t.string :content_sha256, null: false
      t.string :retrieved_from_url
      t.datetime :retrieved_at, null: false
      t.datetime :source_updated_at
      t.datetime :expires_at
      t.bigint :created_by_membership_id
      t.bigint :created_by_user_id
      t.virtual :search_document, type: :tsvector,
        as: "to_tsvector('english', coalesce(content, ''))", stored: true
      t.timestamps
    end
    add_index :knowledge_source_versions, [ :workspace_id, :id ], unique: true
    add_index :knowledge_source_versions, [ :workspace_id, :knowledge_source_id, :id ], unique: true,
      name: "index_knowledge_versions_on_workspace_source_id"
    add_index :knowledge_source_versions, [ :knowledge_source_id, :version_number ], unique: true,
      name: "index_knowledge_versions_on_source_and_number"
    add_index :knowledge_source_versions, :search_document, using: :gin
    add_foreign_key :knowledge_source_versions, :knowledge_sources,
      column: [ :workspace_id, :knowledge_source_id ], primary_key: [ :workspace_id, :id ]
    add_foreign_key :knowledge_source_versions, :stored_attachments,
      column: [ :workspace_id, :stored_attachment_id ], primary_key: [ :workspace_id, :id ]
    add_foreign_key :knowledge_source_versions, :memberships,
      column: [ :workspace_id, :created_by_membership_id, :created_by_user_id ],
      primary_key: [ :workspace_id, :id, :user_id ]
    add_foreign_key :knowledge_source_versions, :users, column: :created_by_user_id
    add_check_constraint :knowledge_source_versions,
      "version_number > 0", name: "knowledge_source_versions_number"
    add_check_constraint :knowledge_source_versions,
      "octet_length(content) BETWEEN 1 AND 1048576", name: "knowledge_source_versions_content_size"
    add_check_constraint :knowledge_source_versions,
      "content_sha256 ~ '^[0-9a-f]{64}$'", name: "knowledge_source_versions_sha256"
    add_check_constraint :knowledge_source_versions,
      "retrieved_from_url IS NULL OR (retrieved_from_url ~ '^https://' AND length(retrieved_from_url) <= 2048)",
      name: "knowledge_source_versions_url_length"
    add_check_constraint :knowledge_source_versions,
      "(created_by_membership_id IS NULL AND created_by_user_id IS NULL) OR " \
      "(created_by_membership_id IS NOT NULL AND created_by_user_id IS NOT NULL)",
      name: "knowledge_source_versions_actor"

    add_foreign_key :knowledge_sources, :knowledge_source_versions,
      column: [ :workspace_id, :id, :current_version_id ],
      primary_key: [ :workspace_id, :knowledge_source_id, :id ],
      name: "fk_knowledge_sources_current_version"

    protect_knowledge_records
  end

  private
    def protect_knowledge_records
      reversible do |direction|
        direction.up do
          execute <<~SQL
            CREATE FUNCTION protect_knowledge_source_version()
            RETURNS trigger
            LANGUAGE plpgsql
            AS $$
            BEGIN
              RAISE EXCEPTION 'knowledge source versions are append only';
            END;
            $$;

            CREATE TRIGGER knowledge_source_versions_append_only
            BEFORE UPDATE OR DELETE ON knowledge_source_versions
            FOR EACH ROW EXECUTE FUNCTION protect_knowledge_source_version();
            CREATE TRIGGER knowledge_source_versions_no_truncate
            BEFORE TRUNCATE ON knowledge_source_versions
            FOR EACH STATEMENT EXECUTE FUNCTION protect_knowledge_source_version();

            CREATE FUNCTION enforce_active_knowledge_source()
            RETURNS trigger
            LANGUAGE plpgsql
            AS $$
            BEGIN
              PERFORM 1 FROM knowledge_sources
              WHERE id = NEW.knowledge_source_id
                AND workspace_id = NEW.workspace_id
                AND deleted_at IS NULL
              FOR UPDATE;
              IF NOT FOUND THEN
                RAISE EXCEPTION 'knowledge source must be active';
              END IF;
              RETURN NEW;
            END;
            $$;

            CREATE TRIGGER knowledge_source_versions_require_active_source
            BEFORE INSERT ON knowledge_source_versions
            FOR EACH ROW EXECUTE FUNCTION enforce_active_knowledge_source();

            CREATE FUNCTION require_current_knowledge_version()
            RETURNS trigger
            LANGUAGE plpgsql
            AS $$
            BEGIN
              IF NOT EXISTS (
                SELECT 1 FROM knowledge_sources
                WHERE id = NEW.id
                  AND workspace_id = NEW.workspace_id
                  AND current_version_id IS NOT NULL
              ) THEN
                RAISE EXCEPTION 'knowledge source must have a current version';
              END IF;
              RETURN NULL;
            END;
            $$;

            CREATE CONSTRAINT TRIGGER knowledge_sources_require_current_version
            AFTER INSERT OR UPDATE ON knowledge_sources
            DEFERRABLE INITIALLY DEFERRED
            FOR EACH ROW EXECUTE FUNCTION require_current_knowledge_version();

            CREATE FUNCTION protect_knowledge_source()
            RETURNS trigger
            LANGUAGE plpgsql
            AS $$
            DECLARE
              old_number integer;
              new_number integer;
            BEGIN
              IF TG_OP = 'UPDATE' AND
                 ROW(OLD.id, OLD.workspace_id, OLD.source_kind, OLD.source_key, OLD.title,
                     OLD.canonical_url, OLD.external_id, OLD.created_at)
                 IS NOT DISTINCT FROM
                 ROW(NEW.id, NEW.workspace_id, NEW.source_kind, NEW.source_key, NEW.title,
                     NEW.canonical_url, NEW.external_id, NEW.created_at) THEN
                IF OLD.deleted_at IS NULL AND NEW.deleted_at IS NULL AND
                   ROW(OLD.deleted_by_membership_id, OLD.deleted_by_user_id)
                   IS NOT DISTINCT FROM
                   ROW(NEW.deleted_by_membership_id, NEW.deleted_by_user_id) AND
                   OLD.current_version_id IS DISTINCT FROM NEW.current_version_id THEN
                  SELECT version_number INTO old_number FROM knowledge_source_versions WHERE id = OLD.current_version_id;
                  SELECT version_number INTO new_number FROM knowledge_source_versions WHERE id = NEW.current_version_id;
                  IF NEW.current_version_id IS NOT NULL AND (OLD.current_version_id IS NULL OR new_number > old_number) THEN
                    RETURN NEW;
                  END IF;
                ELSIF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL AND
                      NEW.deleted_by_membership_id IS NOT NULL AND NEW.deleted_by_user_id IS NOT NULL AND
                      OLD.current_version_id IS NOT DISTINCT FROM NEW.current_version_id THEN
                  RETURN NEW;
                END IF;
              END IF;
              RAISE EXCEPTION 'knowledge source identity and history are durable';
            END;
            $$;

            CREATE TRIGGER knowledge_sources_protect_record
            BEFORE UPDATE OR DELETE ON knowledge_sources
            FOR EACH ROW EXECUTE FUNCTION protect_knowledge_source();
            CREATE TRIGGER knowledge_sources_no_truncate
            BEFORE TRUNCATE ON knowledge_sources
            FOR EACH STATEMENT EXECUTE FUNCTION protect_knowledge_source();
          SQL
        end

        direction.down do
          execute "DROP FUNCTION IF EXISTS protect_knowledge_source() CASCADE"
          execute "DROP FUNCTION IF EXISTS require_current_knowledge_version() CASCADE"
          execute "DROP FUNCTION IF EXISTS enforce_active_knowledge_source() CASCADE"
          execute "DROP FUNCTION IF EXISTS protect_knowledge_source_version() CASCADE"
        end
      end
    end
end
