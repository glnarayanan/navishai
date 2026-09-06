class CreateNotionKnowledgeConnections < ActiveRecord::Migration[8.1]
  def change
    create_table :notion_knowledge_connections do |t|
      t.references :workspace, null: false, foreign_key: true
      t.bigint :workspace_connector_id, null: false
      t.string :name, null: false
      t.jsonb :root_page_ids, null: false, default: []
      t.boolean :enabled, null: false, default: true
      t.timestamps
    end
    add_index :notion_knowledge_connections, [ :workspace_id, :id ], unique: true
    add_foreign_key :notion_knowledge_connections, :workspace_connectors,
      column: [ :workspace_id, :workspace_connector_id ], primary_key: [ :workspace_id, :id ]
    add_check_constraint :notion_knowledge_connections,
      "jsonb_typeof(root_page_ids) = 'array' AND jsonb_array_length(root_page_ids) BETWEEN 1 AND 20", name: "notion_knowledge_roots"

    add_column :knowledge_sources, :notion_knowledge_connection_id, :bigint
    add_foreign_key :knowledge_sources, :notion_knowledge_connections,
      column: [ :workspace_id, :notion_knowledge_connection_id ], primary_key: [ :workspace_id, :id ]
    remove_index :knowledge_sources, [ :workspace_id, :source_kind, :external_id ], unique: true,
      where: "external_id IS NOT NULL AND intercom_connection_id IS NULL", name: "index_knowledge_sources_on_workspace_kind_external"
    add_index :knowledge_sources, [ :workspace_id, :source_kind, :external_id ], unique: true,
      where: "external_id IS NOT NULL AND intercom_connection_id IS NULL AND notion_knowledge_connection_id IS NULL", name: "index_knowledge_sources_on_workspace_kind_external"
    add_index :knowledge_sources, [ :notion_knowledge_connection_id, :external_id ], unique: true,
      where: "notion_knowledge_connection_id IS NOT NULL", name: "index_knowledge_sources_on_notion_page"
    add_check_constraint :knowledge_sources,
      "notion_knowledge_connection_id IS NULL OR (source_kind = 'notion_page' AND intercom_connection_id IS NULL)", name: "knowledge_sources_notion_origin"
    remove_check_constraint :knowledge_sources,
      "source_kind IN ('manual', 'url', 'upload', 'intercom_help_center')", name: "knowledge_sources_kind"
    add_check_constraint :knowledge_sources, "source_kind IN ('manual', 'url', 'upload', 'intercom_help_center', 'notion_page')", name: "knowledge_sources_kind"
    remove_check_constraint :knowledge_sources,
      "(source_kind = 'url' AND canonical_url ~ '^https://' AND external_id IS NULL) OR (source_kind = 'intercom_help_center' AND external_id IS NOT NULL AND canonical_url IS NULL) OR (source_kind IN ('manual', 'upload') AND canonical_url IS NULL AND external_id IS NULL)", name: "knowledge_sources_locator"
    add_check_constraint :knowledge_sources,
      "(source_kind = 'url' AND canonical_url ~ '^https://' AND external_id IS NULL) OR (source_kind IN ('intercom_help_center', 'notion_page') AND external_id IS NOT NULL AND canonical_url IS NULL) OR (source_kind IN ('manual', 'upload') AND canonical_url IS NULL AND external_id IS NULL)", name: "knowledge_sources_locator"

    change_column_null :knowledge_sync_passes, :intercom_connection_id, true
    add_column :knowledge_sync_passes, :notion_knowledge_connection_id, :bigint
    add_column :knowledge_sync_passes, :frontier, :jsonb, default: [], null: false
    add_column :knowledge_sync_passes, :visited, :jsonb, default: [], null: false
    add_foreign_key :knowledge_sync_passes, :notion_knowledge_connections,
      column: [ :workspace_id, :notion_knowledge_connection_id ], primary_key: [ :workspace_id, :id ]
    add_index :knowledge_sync_passes, :notion_knowledge_connection_id, unique: true,
      where: "completed_at IS NULL", name: "index_knowledge_sync_passes_notion_active"
    add_check_constraint :knowledge_sync_passes,
      "(intercom_connection_id IS NULL) <> (notion_knowledge_connection_id IS NULL)", name: "knowledge_sync_pass_origin"
    reversible do |direction|
      direction.up do
        execute <<~SQL
          CREATE FUNCTION protect_notion_knowledge_origin() RETURNS trigger LANGUAGE plpgsql AS $$
          BEGIN
            IF OLD.notion_knowledge_connection_id IS DISTINCT FROM NEW.notion_knowledge_connection_id THEN
              RAISE EXCEPTION 'knowledge origin is immutable';
            END IF;
            RETURN NEW;
          END; $$;
          CREATE TRIGGER knowledge_sources_notion_origin BEFORE UPDATE ON knowledge_sources
          FOR EACH ROW EXECUTE FUNCTION protect_notion_knowledge_origin();
        SQL
      end
      direction.down { execute "DROP FUNCTION protect_notion_knowledge_origin() CASCADE" }
    end
  end
end
