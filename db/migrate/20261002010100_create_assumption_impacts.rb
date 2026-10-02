class CreateAssumptionImpacts < ActiveRecord::Migration[8.1]
  def change
    add_index :source_snapshots, [ :workspace_id, :corpus_id, :source_id, :id ], unique: true
    create_table :assumption_impacts do |t|
      t.bigint :workspace_id, null: false
      t.bigint :corpus_id, null: false
      t.bigint :source_id, null: false
      t.bigint :before_snapshot_id, null: false
      t.bigint :after_snapshot_id, null: false
      t.bigint :source_head_id, null: false
      t.references :requested_by, null: false, foreign_key: { to_table: :users }
      t.boolean :historical, null: false
      t.jsonb :input, null: false
      t.string :input_digest, null: false
      t.jsonb :configuration, null: false
      t.string :request_digest, null: false
      t.string :processing_version, null: false
      t.uuid :request_key, null: false, default: -> { "gen_random_uuid()" }
      t.string :state, null: false, default: "queued"
      t.text :error
      t.datetime :started_at
      t.datetime :finished_at
      t.datetime :created_at, null: false
    end
    add_index :assumption_impacts, [ :workspace_id, :corpus_id, :id ], unique: true
    add_index :assumption_impacts, [ :corpus_id, :request_digest ], unique: true
    add_index :assumption_impacts, :request_key, unique: true
    add_foreign_key :assumption_impacts, :sources, column: [ :workspace_id, :corpus_id, :source_id ], primary_key: [ :workspace_id, :corpus_id, :id ], on_delete: :cascade
    %i[before_snapshot_id after_snapshot_id source_head_id].each do |column|
      add_foreign_key :assumption_impacts, :source_snapshots, column: [ :workspace_id, :corpus_id, :source_id, column ], primary_key: [ :workspace_id, :corpus_id, :source_id, :id ], on_delete: :cascade
    end
    add_check_constraint :assumption_impacts, "before_snapshot_id <> after_snapshot_id AND historical = (after_snapshot_id <> source_head_id) AND jsonb_typeof(input) = 'object' AND jsonb_typeof(configuration) = 'object' AND input_digest ~ '^[0-9a-f]{64}$' AND request_digest ~ '^[0-9a-f]{64}$'"
    add_check_constraint :assumption_impacts, "(state = 'queued' AND started_at IS NULL AND finished_at IS NULL AND error IS NULL) OR (state = 'running' AND started_at IS NOT NULL AND finished_at IS NULL AND error IS NULL) OR (state = 'complete' AND started_at IS NOT NULL AND finished_at IS NOT NULL AND error IS NULL) OR (state = 'interrupted' AND finished_at IS NOT NULL AND error IS NOT NULL)", name: "assumption_impact_claim_state"

    create_table :assumption_impact_inputs do |t|
      t.bigint :workspace_id, null: false
      t.bigint :corpus_id, null: false
      t.bigint :assumption_impact_id, null: false
      t.bigint :scenario_version_id, null: false
    end
    add_index :assumption_impact_inputs, [ :assumption_impact_id, :scenario_version_id ], unique: true, name: "unique_assumption_impact_input"
    add_foreign_key :assumption_impact_inputs, :assumption_impacts, column: [ :workspace_id, :corpus_id, :assumption_impact_id ], primary_key: [ :workspace_id, :corpus_id, :id ], on_delete: :cascade
    add_foreign_key :assumption_impact_inputs, :scenario_versions, column: [ :workspace_id, :corpus_id, :scenario_version_id ], primary_key: [ :workspace_id, :corpus_id, :id ], on_delete: :cascade

    create_table :assumption_impact_results do |t|
      t.bigint :workspace_id, null: false
      t.bigint :corpus_id, null: false
      t.bigint :assumption_impact_id, null: false
      t.jsonb :result, null: false
      t.datetime :created_at, null: false
    end
    add_index :assumption_impact_results, :assumption_impact_id, unique: true
    add_foreign_key :assumption_impact_results, :assumption_impacts, column: [ :workspace_id, :corpus_id, :assumption_impact_id ], primary_key: [ :workspace_id, :corpus_id, :id ], on_delete: :cascade
    add_check_constraint :assumption_impact_results, "jsonb_typeof(result) = 'object' AND result ? 'decision' AND result->>'decision' IN ('proposal', 'abstain', 'error')"

    reversible do |direction|
      direction.up do
        execute <<~SQL
          CREATE FUNCTION prevent_assumption_impact_rewrite() RETURNS trigger LANGUAGE plpgsql AS $$
          BEGIN
            IF TG_OP = 'INSERT' THEN
              IF NEW.state <> 'queued' THEN
                RAISE EXCEPTION 'change analysis must start with an unclaimed queued attempt';
              END IF;
              RETURN NEW;
            END IF;
            IF (to_jsonb(NEW) - ARRAY['state','error','started_at','finished_at'])
                 IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['state','error','started_at','finished_at'])
              OR OLD.state IN ('complete','interrupted')
              OR (OLD.state = 'queued' AND NEW.state NOT IN ('running','interrupted'))
              OR (OLD.state = 'running' AND (NEW.state NOT IN ('complete','interrupted') OR NEW.started_at IS DISTINCT FROM OLD.started_at)) THEN
              RAISE EXCEPTION 'change analysis definition, claim and terminal receipt are immutable';
            END IF;
            IF NEW.state = 'complete' AND NOT EXISTS (
              SELECT 1 FROM assumption_impact_results WHERE assumption_impact_id = NEW.id) THEN
              RAISE EXCEPTION 'complete change analysis requires its immutable result';
            END IF;
            RETURN NEW;
          END; $$;
          CREATE TRIGGER assumption_impact_immutable BEFORE INSERT OR UPDATE ON assumption_impacts
            FOR EACH ROW EXECUTE FUNCTION prevent_assumption_impact_rewrite();
          CREATE TRIGGER assumption_impact_input_immutable BEFORE UPDATE ON assumption_impact_inputs
            FOR EACH ROW EXECUTE FUNCTION prevent_lab_version_update();
          CREATE TRIGGER assumption_impact_result_immutable BEFORE UPDATE ON assumption_impact_results
            FOR EACH ROW EXECUTE FUNCTION prevent_lab_version_update();
          CREATE FUNCTION check_assumption_impact_input() RETURNS trigger LANGUAGE plpgsql AS $$
          BEGIN
            IF NOT EXISTS (SELECT 1 FROM assumption_impacts a,
              jsonb_array_elements(a.input->'scenarios') s
              WHERE a.id = NEW.assumption_impact_id AND a.state = 'queued'
                AND s->>'version_id' = NEW.scenario_version_id::text) THEN
              RAISE EXCEPTION 'change analysis input must be a disclosed fixed version before claim';
            END IF;
            RETURN NEW;
          END; $$;
          CREATE TRIGGER assumption_impact_input_matches_preview BEFORE INSERT ON assumption_impact_inputs
            FOR EACH ROW EXECUTE FUNCTION check_assumption_impact_input();
          CREATE FUNCTION check_assumption_impact_result() RETURNS trigger LANGUAGE plpgsql AS $$
          BEGIN
            IF NOT EXISTS (SELECT 1 FROM assumption_impacts
              WHERE id = NEW.assumption_impact_id AND state = 'running') THEN
              RAISE EXCEPTION 'change analysis result requires a claimed running attempt';
            END IF;
            RETURN NEW;
          END; $$;
          CREATE TRIGGER assumption_impact_result_matches_claim BEFORE INSERT ON assumption_impact_results
            FOR EACH ROW EXECUTE FUNCTION check_assumption_impact_result();
        SQL
      end
      direction.down do
        execute "DROP FUNCTION check_assumption_impact_result() CASCADE"
        execute "DROP FUNCTION check_assumption_impact_input() CASCADE"
        execute "DROP FUNCTION prevent_assumption_impact_rewrite() CASCADE"
      end
    end
  end
end
