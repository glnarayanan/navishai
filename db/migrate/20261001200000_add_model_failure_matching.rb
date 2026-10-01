class AddModelFailureMatching < ActiveRecord::Migration[8.1]
  def change
    create_table :model_failure_matchings do |t|
      t.bigint :workspace_id, null: false
      t.bigint :corpus_id, null: false
      t.bigint :corpus_item_id, null: false
      t.references :requested_by, null: false, foreign_key: { to_table: :users }
      t.jsonb :configuration, null: false
      t.jsonb :input, null: false
      t.string :input_digest, null: false
      t.string :processing_version, null: false
      t.uuid :request_key, null: false, default: -> { "gen_random_uuid()" }
      t.string :state, null: false, default: "queued"
      t.text :error
      t.datetime :started_at
      t.datetime :finished_at
      t.datetime :created_at, null: false
    end
    add_index :model_failure_matchings, [ :corpus_item_id, :input_digest, :configuration ], unique: true, name: "model_matching_fixed_request"
    add_index :model_failure_matchings, :request_key, unique: true
    add_index :model_failure_matchings, [ :workspace_id, :corpus_id, :id ], unique: true
    add_foreign_key :model_failure_matchings, :corpus_items, column: [ :workspace_id, :corpus_id, :corpus_item_id ], primary_key: [ :workspace_id, :corpus_id, :id ], on_delete: :cascade
    add_check_constraint :model_failure_matchings, "state IN ('queued', 'running', 'complete', 'interrupted') AND jsonb_typeof(configuration) = 'object' AND jsonb_typeof(input) = 'object' AND input_digest ~ '^[0-9a-f]{64}$'"

    create_table :model_failure_matching_candidates do |t|
      t.bigint :workspace_id, null: false
      t.bigint :corpus_id, null: false
      t.bigint :model_failure_matching_id, null: false
      t.bigint :scenario_version_id, null: false
    end
    add_index :model_failure_matching_candidates, [ :model_failure_matching_id, :scenario_version_id ], unique: true, name: "model_matching_fixed_candidate"
    add_foreign_key :model_failure_matching_candidates, :model_failure_matchings, column: [ :workspace_id, :corpus_id, :model_failure_matching_id ], primary_key: [ :workspace_id, :corpus_id, :id ], on_delete: :cascade
    add_foreign_key :model_failure_matching_candidates, :scenario_versions, column: [ :workspace_id, :corpus_id, :scenario_version_id ], primary_key: [ :workspace_id, :corpus_id, :id ], on_delete: :cascade

    create_table :model_failure_matching_results do |t|
      t.bigint :workspace_id, null: false
      t.bigint :corpus_id, null: false
      t.bigint :model_failure_matching_id, null: false
      t.jsonb :result, null: false
      t.datetime :created_at, null: false
    end
    add_index :model_failure_matching_results, :model_failure_matching_id, unique: true
    add_foreign_key :model_failure_matching_results, :model_failure_matchings, column: [ :workspace_id, :corpus_id, :model_failure_matching_id ], primary_key: [ :workspace_id, :corpus_id, :id ], on_delete: :cascade
    add_check_constraint :model_failure_matching_results, "jsonb_typeof(result) = 'object' AND COALESCE(result->>'decision', '') IN ('suggestions', 'error')", name: "model_matching_result_decision"

    reversible do |direction|
      direction.up do
        execute "CREATE TRIGGER model_matching_definition_immutable BEFORE UPDATE ON model_failure_matchings FOR EACH ROW EXECUTE FUNCTION prevent_evaluation_run_rebind()"
        %w[model_failure_matching_candidates model_failure_matching_results].each do |table|
          execute "CREATE TRIGGER #{table}_immutable BEFORE UPDATE ON #{table} FOR EACH ROW EXECUTE FUNCTION prevent_lab_version_update()"
        end
        # A request contains every candidate's disclosed definition; losing any
        # candidate must remove the entire private copy, not just the join row.
        execute <<~SQL
          CREATE FUNCTION purge_model_matching_copy() RETURNS trigger AS $$
          BEGIN
            DELETE FROM model_failure_matchings WHERE id = OLD.model_failure_matching_id;
            RETURN OLD;
          END;
          $$ LANGUAGE plpgsql;
          CREATE TRIGGER model_matching_candidate_purge AFTER DELETE ON model_failure_matching_candidates
            FOR EACH ROW EXECUTE FUNCTION purge_model_matching_copy();
        SQL
      end
      direction.down do
        execute "DROP TRIGGER model_matching_candidate_purge ON model_failure_matching_candidates"
        execute "DROP FUNCTION purge_model_matching_copy()"
        execute "DROP TRIGGER model_matching_definition_immutable ON model_failure_matchings"
        %w[model_failure_matching_candidates model_failure_matching_results].each { |table| execute "DROP TRIGGER #{table}_immutable ON #{table}" }
      end
    end
  end
end
