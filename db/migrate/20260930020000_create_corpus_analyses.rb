class CreateCorpusAnalyses < ActiveRecord::Migration[8.1]
  def change
    create_table :corpus_analyses do |t|
      t.bigint :workspace_id, null: false
      t.bigint :corpus_id, null: false
      t.references :requested_by, null: false, foreign_key: { to_table: :users }
      t.string :processing_method, null: false
      t.string :state, null: false, default: "queued"
      t.integer :scenario_limit, null: false
      t.text :error
      t.jsonb :summary, null: false, default: {}
      t.timestamps
    end
    add_index :corpus_analyses, [ :workspace_id, :corpus_id, :id ], unique: true
    add_foreign_key :corpus_analyses, :corpora, column: [ :workspace_id, :corpus_id ], primary_key: [ :workspace_id, :id ], on_delete: :cascade
    add_check_constraint :corpus_analyses, "state IN ('queued', 'complete', 'failed') AND scenario_limit BETWEEN 1 AND 100"

    create_table :corpus_analysis_inputs do |t|
      t.bigint :workspace_id, null: false
      t.bigint :corpus_id, null: false
      t.bigint :corpus_analysis_id, null: false
      t.bigint :corpus_item_id, null: false
    end
    add_index :corpus_analysis_inputs, [ :corpus_analysis_id, :corpus_item_id ], unique: true
    add_foreign_key :corpus_analysis_inputs, :corpus_analyses, column: [ :workspace_id, :corpus_id, :corpus_analysis_id ], primary_key: [ :workspace_id, :corpus_id, :id ], on_delete: :cascade
    add_foreign_key :corpus_analysis_inputs, :corpus_items, column: [ :workspace_id, :corpus_id, :corpus_item_id ], primary_key: [ :workspace_id, :corpus_id, :id ], on_delete: :cascade

    create_table :issue_clusters do |t|
      t.bigint :workspace_id, null: false
      t.bigint :corpus_id, null: false
      t.bigint :corpus_analysis_id, null: false
      t.string :proposed_label, null: false
      t.jsonb :signals, null: false, default: {}
    end
    add_index :issue_clusters, [ :workspace_id, :corpus_id, :id ], unique: true
    add_foreign_key :issue_clusters, :corpus_analyses, column: [ :workspace_id, :corpus_id, :corpus_analysis_id ], primary_key: [ :workspace_id, :corpus_id, :id ], on_delete: :cascade

    create_table :cluster_members do |t|
      t.bigint :workspace_id, null: false
      t.bigint :corpus_id, null: false
      t.bigint :issue_cluster_id, null: false
      t.bigint :corpus_item_id, null: false
      t.jsonb :signals, null: false, default: []
      t.text :selection_reason
    end
    add_index :cluster_members, [ :issue_cluster_id, :corpus_item_id ], unique: true
    add_foreign_key :cluster_members, :issue_clusters, column: [ :workspace_id, :corpus_id, :issue_cluster_id ], primary_key: [ :workspace_id, :corpus_id, :id ], on_delete: :cascade
    add_foreign_key :cluster_members, :corpus_items, column: [ :workspace_id, :corpus_id, :corpus_item_id ], primary_key: [ :workspace_id, :corpus_id, :id ], on_delete: :cascade

    create_table :taxonomy_versions do |t|
      t.bigint :workspace_id, null: false
      t.bigint :corpus_id, null: false
      t.bigint :corpus_analysis_id, null: false
      t.references :reviewed_by, null: false, foreign_key: { to_table: :users }
      t.integer :number, null: false
      t.jsonb :labels, null: false, default: {}
      t.datetime :created_at, null: false
    end
    add_index :taxonomy_versions, [ :corpus_analysis_id, :number ], unique: true
    add_foreign_key :taxonomy_versions, :corpus_analyses, column: [ :workspace_id, :corpus_id, :corpus_analysis_id ], primary_key: [ :workspace_id, :corpus_id, :id ], on_delete: :cascade
    reversible do |direction|
      direction.up do
        %w[corpus_analysis_inputs issue_clusters cluster_members taxonomy_versions].each do |table|
          execute "CREATE TRIGGER #{table}_immutable BEFORE UPDATE ON #{table} FOR EACH ROW EXECUTE FUNCTION prevent_lab_version_update()"
        end
      end
      direction.down do
        %w[corpus_analysis_inputs issue_clusters cluster_members taxonomy_versions].each { |table| execute "DROP TRIGGER #{table}_immutable ON #{table}" }
      end
    end
  end
end
