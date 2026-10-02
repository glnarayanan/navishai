class CreateScenarios < ActiveRecord::Migration[8.1]
  def change
    create_table :scenarios do |t|
      t.bigint :workspace_id, null: false
      t.bigint :corpus_id, null: false
      t.bigint :corpus_item_id, null: false
      t.bigint :cluster_member_id
      t.bigint :parent_version_id
      t.bigint :current_version_id
      t.bigint :merged_into_id
      t.timestamps
    end
    add_index :scenarios, [ :workspace_id, :corpus_id, :id ], unique: true
    add_index :scenarios, :cluster_member_id, unique: true
    add_index :cluster_members, [ :workspace_id, :corpus_id, :id ], unique: true
    add_foreign_key :scenarios, :corpus_items, column: [ :workspace_id, :corpus_id, :corpus_item_id ], primary_key: [ :workspace_id, :corpus_id, :id ], on_delete: :cascade
    add_foreign_key :scenarios, :cluster_members, column: [ :workspace_id, :corpus_id, :cluster_member_id ], primary_key: [ :workspace_id, :corpus_id, :id ], on_delete: :cascade
    add_foreign_key :scenarios, :scenarios, column: [ :workspace_id, :corpus_id, :merged_into_id ], primary_key: [ :workspace_id, :corpus_id, :id ], on_delete: :cascade

    create_table :scenario_versions do |t|
      t.bigint :workspace_id, null: false
      t.bigint :corpus_id, null: false
      t.bigint :scenario_id, null: false
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.integer :number, null: false
      t.string :origin, null: false
      t.string :title, null: false
      t.text :situation, null: false
      t.string :taxonomy_label, null: false
      t.string :importance, null: false
      t.jsonb :known_facts, null: false, default: {}
      t.jsonb :hidden_facts, null: false, default: {}
      t.jsonb :requirements, null: false, default: {}
      t.jsonb :mutation, null: false, default: {}
      t.text :selection_reason, null: false
      t.datetime :created_at, null: false
    end
    add_index :scenario_versions, [ :scenario_id, :number ], unique: true
    add_index :scenario_versions, [ :workspace_id, :corpus_id, :id ], unique: true
    add_index :scenario_versions, [ :workspace_id, :corpus_id, :scenario_id, :id ], unique: true
    add_foreign_key :scenario_versions, :scenarios, column: [ :workspace_id, :corpus_id, :scenario_id ], primary_key: [ :workspace_id, :corpus_id, :id ], on_delete: :cascade
    add_foreign_key :scenarios, :scenario_versions, column: [ :workspace_id, :corpus_id, :id, :current_version_id ], primary_key: [ :workspace_id, :corpus_id, :scenario_id, :id ], on_delete: :cascade
    add_foreign_key :scenarios, :scenario_versions, column: [ :workspace_id, :corpus_id, :parent_version_id ], primary_key: [ :workspace_id, :corpus_id, :id ], on_delete: :cascade
    add_check_constraint :scenario_versions, "number > 0 AND origin IN ('mined', 'expert', 'variant') AND importance IN ('normal', 'high', 'critical') AND jsonb_typeof(known_facts) = 'object' AND jsonb_typeof(hidden_facts) = 'object' AND jsonb_typeof(requirements) = 'object'"

    create_table :scenario_evidence do |t|
      t.bigint :workspace_id, null: false
      t.bigint :corpus_id, null: false
      t.bigint :scenario_version_id, null: false
      t.bigint :corpus_item_id, null: false
      t.string :kind, null: false
      t.text :excerpt, null: false
    end
    add_index :scenario_evidence, [ :scenario_version_id, :corpus_item_id, :kind ], unique: true
    add_foreign_key :scenario_evidence, :scenario_versions, column: [ :workspace_id, :corpus_id, :scenario_version_id ], primary_key: [ :workspace_id, :corpus_id, :id ], on_delete: :cascade
    add_foreign_key :scenario_evidence, :corpus_items, column: [ :workspace_id, :corpus_id, :corpus_item_id ], primary_key: [ :workspace_id, :corpus_id, :id ], on_delete: :cascade
    add_check_constraint :scenario_evidence, "kind IN ('expectation', 'knowledge') AND length(excerpt) BETWEEN 1 AND 4000"

    create_table :scenario_reviews do |t|
      t.bigint :workspace_id, null: false
      t.bigint :corpus_id, null: false
      t.bigint :scenario_version_id, null: false
      t.references :reviewed_by, null: false, foreign_key: { to_table: :users }
      t.string :decision, null: false
      t.text :note, null: false
      t.bigint :merged_version_id
      t.datetime :created_at, null: false
    end
    add_index :scenario_reviews, [ :workspace_id, :corpus_id, :id ], unique: true
    add_foreign_key :scenario_reviews, :scenario_versions, column: [ :workspace_id, :corpus_id, :scenario_version_id ], primary_key: [ :workspace_id, :corpus_id, :id ], on_delete: :cascade
    add_foreign_key :scenario_reviews, :scenario_versions, column: [ :workspace_id, :corpus_id, :merged_version_id ], primary_key: [ :workspace_id, :corpus_id, :id ], on_delete: :cascade
    add_check_constraint :scenario_reviews, "decision IN ('approve', 'reject', 'merge') AND (decision = 'merge') = (merged_version_id IS NOT NULL)"
    reversible do |direction|
      direction.up do
        %w[scenario_versions scenario_evidence scenario_reviews].each { |table| execute "CREATE TRIGGER #{table}_immutable BEFORE UPDATE ON #{table} FOR EACH ROW EXECUTE FUNCTION prevent_lab_version_update()" }
      end
      direction.down do
        %w[scenario_versions scenario_evidence scenario_reviews].each { |table| execute "DROP TRIGGER #{table}_immutable ON #{table}" }
      end
    end
  end
end
