class AddTraceScenarioDecisions < ActiveRecord::Migration[8.1]
  def change
    create_table :trace_scenario_decisions do |t|
      t.bigint :workspace_id, null: false
      t.bigint :corpus_id, null: false
      t.bigint :corpus_item_id, null: false
      t.bigint :scenario_version_id, null: false
      t.references :reviewed_by, null: false, foreign_key: { to_table: :users }
      t.string :decision, null: false
      t.text :reason, null: false
      t.datetime :created_at, null: false
    end
    add_index :trace_scenario_decisions, [ :corpus_item_id, :scenario_version_id, :reviewed_by_id, :id ], name: "trace_decision_history"
    add_foreign_key :trace_scenario_decisions, :corpus_items, column: [ :workspace_id, :corpus_id, :corpus_item_id ], primary_key: [ :workspace_id, :corpus_id, :id ], on_delete: :cascade
    add_foreign_key :trace_scenario_decisions, :scenario_versions, column: [ :workspace_id, :corpus_id, :scenario_version_id ], primary_key: [ :workspace_id, :corpus_id, :id ], on_delete: :cascade
    add_check_constraint :trace_scenario_decisions, "decision IN ('match', 'different', 'uncertain') AND length(btrim(reason)) BETWEEN 1 AND 2000"
    reversible do |direction|
      direction.up { execute "CREATE TRIGGER trace_scenario_decisions_immutable BEFORE UPDATE ON trace_scenario_decisions FOR EACH ROW EXECUTE FUNCTION prevent_lab_version_update()" }
      direction.down { execute "DROP TRIGGER trace_scenario_decisions_immutable ON trace_scenario_decisions" }
    end
  end
end
