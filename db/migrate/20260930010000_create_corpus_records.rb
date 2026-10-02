class CreateCorpusRecords < ActiveRecord::Migration[8.1]
  def change
    create_table :corpora do |t|
      t.references :workspace, null: false, foreign_key: true
      t.string :name, null: false
      t.timestamps
    end
    add_index :corpora, [ :workspace_id, :id ], unique: true

    create_table :sources do |t|
      t.bigint :workspace_id, null: false
      t.bigint :corpus_id, null: false
      t.string :name, null: false
      t.string :kind, null: false
      t.bigint :current_snapshot_id
      t.datetime :expires_at, null: false
      t.timestamps
    end
    add_index :sources, [ :corpus_id, :name, :kind ], unique: true
    add_index :sources, [ :workspace_id, :corpus_id, :id ], unique: true
    add_foreign_key :sources, :corpora, column: [ :workspace_id, :corpus_id ], primary_key: [ :workspace_id, :id ], on_delete: :cascade
    add_check_constraint :sources, "kind IN ('conversations', 'document')"

    create_table :source_snapshots do |t|
      t.bigint :workspace_id, null: false
      t.bigint :corpus_id, null: false
      t.bigint :source_id, null: false
      t.integer :number, null: false
      t.string :digest, null: false
      t.string :redaction, null: false
      t.string :processing_version, null: false
      t.references :imported_by, null: false, foreign_key: { to_table: :users }
      t.datetime :created_at, null: false
    end
    add_index :source_snapshots, [ :source_id, :number ], unique: true
    add_index :source_snapshots, [ :source_id, :digest, :redaction ], unique: true
    add_index :source_snapshots, [ :workspace_id, :corpus_id, :id ], unique: true
    add_index :source_snapshots, [ :workspace_id, :source_id, :id ], unique: true
    add_foreign_key :source_snapshots, :sources, column: [ :workspace_id, :corpus_id, :source_id ], primary_key: [ :workspace_id, :corpus_id, :id ], on_delete: :cascade
    add_foreign_key :sources, :source_snapshots, column: [ :workspace_id, :id, :current_snapshot_id ], primary_key: [ :workspace_id, :source_id, :id ]
    add_check_constraint :source_snapshots, "number > 0 AND digest ~ '^[0-9a-f]{64}$' AND redaction IN ('email', 'none')"

    create_table :corpus_items do |t|
      t.bigint :workspace_id, null: false
      t.bigint :corpus_id, null: false
      t.bigint :source_snapshot_id, null: false
      t.string :external_id, null: false
      t.string :title, null: false
      t.text :content, null: false
      t.jsonb :context, null: false, default: {}
      t.datetime :created_at, null: false
    end
    add_index :corpus_items, [ :source_snapshot_id, :external_id ], unique: true
    add_index :corpus_items, [ :workspace_id, :corpus_id, :id ], unique: true
    add_foreign_key :corpus_items, :source_snapshots, column: [ :workspace_id, :corpus_id, :source_snapshot_id ], primary_key: [ :workspace_id, :corpus_id, :id ], on_delete: :cascade
    add_check_constraint :corpus_items, "jsonb_typeof(context) = 'object' AND length(content) BETWEEN 1 AND 100000"

    reversible do |direction|
      direction.up do
        execute <<~SQL
          CREATE FUNCTION prevent_lab_version_update() RETURNS trigger LANGUAGE plpgsql AS $$
          BEGIN RAISE EXCEPTION 'lab versions are immutable'; END; $$;
          CREATE TRIGGER source_snapshots_immutable BEFORE UPDATE ON source_snapshots
            FOR EACH ROW EXECUTE FUNCTION prevent_lab_version_update();
          CREATE TRIGGER corpus_items_immutable BEFORE UPDATE ON corpus_items
            FOR EACH ROW EXECUTE FUNCTION prevent_lab_version_update();
        SQL
      end
      direction.down do
        execute "DROP FUNCTION prevent_lab_version_update() CASCADE"
      end
    end
  end
end
