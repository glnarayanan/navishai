class AddCorpusDiscoveryBatches < ActiveRecord::Migration[8.1]
  def change
    add_column :corpus_analyses, :call_plan, :jsonb, null: false, default: {}
    create_table :corpus_discovery_batches do |t|
      t.bigint :workspace_id, null: false
      t.bigint :corpus_id, null: false
      t.bigint :corpus_analysis_id, null: false
      t.uuid :request_key, null: false, default: -> { "gen_random_uuid()" }
      t.string :phase, null: false
      t.integer :position, null: false
      t.jsonb :input_refs, null: false
      t.string :input_digest, null: false
      t.string :state, null: false, default: "queued"
      t.jsonb :result
      t.datetime :started_at
      t.datetime :finished_at
      t.datetime :created_at, null: false
    end
    add_index :corpus_discovery_batches, :request_key, unique: true
    add_index :corpus_discovery_batches, [ :corpus_analysis_id, :position ], unique: true
    add_foreign_key :corpus_discovery_batches, :corpus_analyses, column: [ :workspace_id, :corpus_id, :corpus_analysis_id ], primary_key: [ :workspace_id, :corpus_id, :id ], on_delete: :cascade
    add_check_constraint :corpus_discovery_batches, "phase IN ('discovery', 'reducer') AND position BETWEEN 1 AND 31 AND jsonb_typeof(input_refs) = 'array' AND state IN ('queued', 'running', 'proposal', 'abstain', 'error') AND (result IS NULL OR jsonb_typeof(result) = 'object')"
    add_check_constraint :corpus_discovery_batches, "(state = 'queued' AND started_at IS NULL AND finished_at IS NULL AND result IS NULL) OR (state = 'running' AND started_at IS NOT NULL AND finished_at IS NULL AND result IS NULL) OR (state IN ('proposal', 'abstain', 'error') AND started_at IS NOT NULL AND finished_at IS NOT NULL AND result IS NOT NULL AND result ? 'decision' AND COALESCE(result->>'decision' = state, false))", name: "corpus_batch_receipt_matches_claim"
    reversible do |direction|
      direction.up do
        execute <<~SQL
          CREATE FUNCTION prevent_corpus_batch_rewrite() RETURNS trigger AS $$
          BEGIN
            IF (to_jsonb(NEW) - ARRAY['state', 'result', 'started_at', 'finished_at'])
               IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['state', 'result', 'started_at', 'finished_at'])
               OR (OLD.state IN ('proposal', 'abstain', 'error') AND to_jsonb(NEW) IS DISTINCT FROM to_jsonb(OLD))
               OR (OLD.state = 'running' AND NEW.state NOT IN ('proposal', 'abstain', 'error'))
               OR (OLD.state = 'running' AND NEW.started_at IS DISTINCT FROM OLD.started_at)
               OR (OLD.state = 'queued' AND NEW.state <> 'running') THEN
              RAISE EXCEPTION 'batch definition, claim and terminal receipt are immutable';
            END IF;
            RETURN NEW;
          END;
          $$ LANGUAGE plpgsql;
          CREATE TRIGGER corpus_discovery_batch_immutable BEFORE UPDATE ON corpus_discovery_batches FOR EACH ROW EXECUTE FUNCTION prevent_corpus_batch_rewrite();
        SQL
      end
      direction.down do
        execute "DROP TRIGGER corpus_discovery_batch_immutable ON corpus_discovery_batches"
        execute "DROP FUNCTION prevent_corpus_batch_rewrite()"
      end
    end
  end
end
