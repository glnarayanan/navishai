class AddScenarioProposals < ActiveRecord::Migration[8.1]
  def change
    create_table :scenario_proposals do |t|
      t.bigint :workspace_id, null: false
      t.bigint :corpus_id, null: false
      t.bigint :scenario_version_id, null: false
      t.references :requested_by, null: false, foreign_key: { to_table: :users }
      t.jsonb :configuration, null: false
      t.jsonb :input, null: false
      t.string :processing_version, null: false
      t.uuid :request_key, null: false, default: -> { "gen_random_uuid()" }
      t.string :state, null: false, default: "queued"
      t.text :error
      t.datetime :started_at
      t.datetime :finished_at
      t.datetime :created_at, null: false
    end
    add_index :scenario_proposals, :scenario_version_id, unique: true
    add_index :scenario_proposals, :request_key, unique: true
    add_index :scenario_proposals, [ :workspace_id, :corpus_id, :id ], unique: true
    add_foreign_key :scenario_proposals, :scenario_versions, column: [ :workspace_id, :corpus_id, :scenario_version_id ], primary_key: [ :workspace_id, :corpus_id, :id ], on_delete: :cascade
    add_check_constraint :scenario_proposals, "state IN ('queued', 'running', 'complete', 'interrupted') AND jsonb_typeof(configuration) = 'object' AND jsonb_typeof(input) = 'object'"

    create_table :scenario_proposal_results do |t|
      t.bigint :workspace_id, null: false
      t.bigint :corpus_id, null: false
      t.bigint :scenario_proposal_id, null: false
      t.jsonb :result, null: false
      t.datetime :created_at, null: false
    end
    add_index :scenario_proposal_results, :scenario_proposal_id, unique: true
    add_foreign_key :scenario_proposal_results, :scenario_proposals, column: [ :workspace_id, :corpus_id, :scenario_proposal_id ], primary_key: [ :workspace_id, :corpus_id, :id ], on_delete: :cascade
    add_check_constraint :scenario_proposal_results, "jsonb_typeof(result) = 'object' AND result ? 'decision' AND result->>'decision' IN ('proposal', 'abstain', 'error')"
    reversible do |direction|
      direction.up do
        execute "CREATE TRIGGER scenario_proposal_definition_immutable BEFORE UPDATE ON scenario_proposals FOR EACH ROW EXECUTE FUNCTION prevent_evaluation_run_rebind()"
        execute "CREATE TRIGGER scenario_proposal_result_immutable BEFORE UPDATE ON scenario_proposal_results FOR EACH ROW EXECUTE FUNCTION prevent_lab_version_update()"
      end
      direction.down do
        execute "DROP TRIGGER scenario_proposal_definition_immutable ON scenario_proposals"
        execute "DROP TRIGGER scenario_proposal_result_immutable ON scenario_proposal_results"
      end
    end
  end
end
