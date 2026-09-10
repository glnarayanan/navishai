class CreateKnowledgeSyncPasses < ActiveRecord::Migration[8.1]
  def change
    add_column :intercom_connections, :help_center_sync_enabled, :boolean, default: false, null: false
    add_column :knowledge_sources, :intercom_connection_id, :bigint
    add_foreign_key :knowledge_sources, :intercom_connections,
      column: [ :workspace_id, :intercom_connection_id ], primary_key: [ :workspace_id, :id ]
    remove_index :knowledge_sources, [ :workspace_id, :source_kind, :external_id ], unique: true,
      where: "external_id IS NOT NULL", name: "index_knowledge_sources_on_workspace_kind_external"
    add_index :knowledge_sources, [ :workspace_id, :source_kind, :external_id ], unique: true,
      where: "external_id IS NOT NULL AND intercom_connection_id IS NULL", name: "index_knowledge_sources_on_workspace_kind_external"
    add_index :knowledge_sources, [ :workspace_id, :intercom_connection_id, :external_id ], unique: true,
      where: "intercom_connection_id IS NOT NULL", name: "index_knowledge_sources_on_connection_article"
    add_check_constraint :knowledge_sources, "intercom_connection_id IS NULL OR source_kind = 'intercom_help_center'", name: "knowledge_sources_origin_kind"
    add_column :knowledge_source_versions, :source_title, :string
    add_check_constraint :knowledge_source_versions, "source_title IS NULL OR length(source_title) BETWEEN 1 AND 200", name: "knowledge_versions_title"

    create_table :knowledge_sync_passes do |t|
      t.references :workspace, null: false, foreign_key: true
      t.bigint :intercom_connection_id, null: false
      t.string :status, null: false, default: "pending"
      t.string :cursor
      t.integer :page_count, null: false, default: 0
      t.bigint :reconciliation_position, null: false, default: 0
      t.boolean :enumerated, null: false, default: false
      t.string :failure_code
      t.datetime :completed_at
      t.timestamps
    end
    add_index :knowledge_sync_passes, [ :workspace_id, :id ], unique: true
    add_index :knowledge_sync_passes, :intercom_connection_id, unique: true,
      where: "completed_at IS NULL", name: "index_knowledge_sync_passes_active"
    add_foreign_key :knowledge_sync_passes, :intercom_connections,
      column: [ :workspace_id, :intercom_connection_id ], primary_key: [ :workspace_id, :id ]
    add_check_constraint :knowledge_sync_passes,
      "status IN ('pending', 'failed', 'completed') AND page_count BETWEEN 0 AND 1000 AND reconciliation_position >= 0 AND " \
      "(cursor IS NULL OR octet_length(cursor) <= 2048) AND (failure_code IS NULL OR failure_code ~ '^[a-z_]{1,64}$') AND " \
      "((status = 'completed') = (completed_at IS NOT NULL))", name: "knowledge_sync_passes_state"

    create_table :knowledge_sync_observations do |t|
      t.references :workspace, null: false, foreign_key: true
      t.bigint :knowledge_source_id, null: false
      t.bigint :last_seen_pass_id, null: false
      t.datetime :observed_at, null: false
      t.integer :missing_passes, null: false, default: 0
      t.datetime :unavailable_at
      t.datetime :retired_at
      t.timestamps
    end
    add_index :knowledge_sync_observations, :knowledge_source_id, unique: true
    add_index :knowledge_sync_observations, [ :workspace_id, :id ], unique: true
    add_foreign_key :knowledge_sync_observations, :knowledge_sources,
      column: [ :workspace_id, :knowledge_source_id ], primary_key: [ :workspace_id, :id ]
    add_foreign_key :knowledge_sync_observations, :knowledge_sync_passes,
      column: [ :workspace_id, :last_seen_pass_id ], primary_key: [ :workspace_id, :id ]
    add_check_constraint :knowledge_sync_observations,
      "missing_passes BETWEEN 0 AND 2 AND ((missing_passes = 0 AND unavailable_at IS NULL AND retired_at IS NULL) OR " \
      "(missing_passes = 1 AND unavailable_at IS NOT NULL AND retired_at IS NULL) OR " \
      "(missing_passes = 2 AND unavailable_at IS NOT NULL AND retired_at IS NOT NULL))", name: "knowledge_sync_observations_state"
    reversible do |dir|
      dir.up do
        execute <<~SQL
          CREATE FUNCTION protect_knowledge_origin() RETURNS trigger LANGUAGE plpgsql AS $$
          BEGIN
            IF OLD.intercom_connection_id IS DISTINCT FROM NEW.intercom_connection_id THEN
              RAISE EXCEPTION 'knowledge origin is immutable';
            END IF;
            RETURN NEW;
          END; $$;
          CREATE TRIGGER knowledge_sources_origin BEFORE UPDATE ON knowledge_sources
          FOR EACH ROW EXECUTE FUNCTION protect_knowledge_origin();
        SQL
      end
      dir.down { execute "DROP FUNCTION protect_knowledge_origin() CASCADE" }
    end
  end
end
