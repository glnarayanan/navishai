class AddModelCorpusDiscovery < ActiveRecord::Migration[8.1]
  def change
    add_column :corpus_analyses, :configuration, :jsonb, null: false, default: {}
    add_column :corpus_analyses, :input_digest, :string
    add_column :corpus_analyses, :request_key, :uuid, null: false, default: -> { "gen_random_uuid()" }
    add_column :corpus_analyses, :started_at, :datetime
    add_column :corpus_analyses, :finished_at, :datetime
    add_index :corpus_analyses, :request_key, unique: true
    remove_check_constraint :corpus_analyses, "state IN ('queued', 'complete', 'failed') AND scenario_limit BETWEEN 1 AND 100"
    add_check_constraint :corpus_analyses, "state IN ('queued', 'running', 'complete', 'failed') AND scenario_limit BETWEEN 1 AND 100 AND jsonb_typeof(configuration) = 'object'"

    create_table :corpus_analysis_results do |t|
      t.bigint :workspace_id, null: false
      t.bigint :corpus_id, null: false
      t.bigint :corpus_analysis_id, null: false
      t.jsonb :result, null: false
      t.datetime :created_at, null: false
    end
    add_index :corpus_analysis_results, :corpus_analysis_id, unique: true
    add_foreign_key :corpus_analysis_results, :corpus_analyses, column: [ :workspace_id, :corpus_id, :corpus_analysis_id ], primary_key: [ :workspace_id, :corpus_id, :id ], on_delete: :cascade
    add_check_constraint :corpus_analysis_results, "jsonb_typeof(result) = 'object' AND result ? 'decision' AND result->>'decision' IN ('proposal', 'abstain', 'error')"
    reversible do |direction|
      direction.up do
        execute <<~SQL
          CREATE FUNCTION prevent_corpus_analysis_rewrite() RETURNS trigger AS $$
          BEGIN
            IF (to_jsonb(NEW) - ARRAY['state', 'summary', 'error', 'started_at', 'finished_at', 'updated_at'])
               IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['state', 'summary', 'error', 'started_at', 'finished_at', 'updated_at'])
               OR (OLD.state IN ('complete', 'failed') AND to_jsonb(NEW) IS DISTINCT FROM to_jsonb(OLD)) THEN
              RAISE EXCEPTION 'corpus analysis definition and terminal result are immutable';
            END IF;
            RETURN NEW;
          END;
          $$ LANGUAGE plpgsql;
          CREATE TRIGGER corpus_analysis_definition_immutable BEFORE UPDATE ON corpus_analyses FOR EACH ROW EXECUTE FUNCTION prevent_corpus_analysis_rewrite();
          CREATE TRIGGER corpus_analysis_result_immutable BEFORE UPDATE ON corpus_analysis_results FOR EACH ROW EXECUTE FUNCTION prevent_lab_version_update();
        SQL
      end
      direction.down do
        execute "DROP TRIGGER corpus_analysis_result_immutable ON corpus_analysis_results"
        execute "DROP TRIGGER corpus_analysis_definition_immutable ON corpus_analyses"
        execute "DROP FUNCTION prevent_corpus_analysis_rewrite()"
      end
    end
  end
end
