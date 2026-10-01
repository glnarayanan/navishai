class CreateTraceFailureDiscoveries < ActiveRecord::Migration[8.1]
  def change
    create_table :trace_failure_discoveries do |t|
      t.bigint :workspace_id, null: false
      t.bigint :corpus_id, null: false
      t.references :requested_by, null: false, foreign_key: { to_table: :users }
      t.jsonb :configuration, null: false
      t.jsonb :input_content, null: false
      t.string :input_digest, null: false
      t.string :processing_version, null: false
      t.uuid :request_key, null: false, default: -> { "gen_random_uuid()" }
      t.string :state, null: false, default: "queued"
      t.text :error
      t.datetime :started_at
      t.datetime :finished_at
      t.datetime :created_at, null: false
    end
    add_index :trace_failure_discoveries, :request_key, unique: true
    add_index :trace_failure_discoveries, [ :workspace_id, :corpus_id, :id ], unique: true
    add_foreign_key :trace_failure_discoveries, :corpora, column: [ :workspace_id, :corpus_id ], primary_key: [ :workspace_id, :id ], on_delete: :cascade
    add_check_constraint :trace_failure_discoveries, "state IN ('queued', 'running', 'complete', 'interrupted') AND jsonb_typeof(input_content) = 'object' AND jsonb_typeof(configuration) = 'object'"
    add_check_constraint :trace_failure_discoveries, "(state <> 'running' OR (started_at IS NOT NULL AND finished_at IS NULL)) AND (state NOT IN ('complete', 'interrupted') OR finished_at IS NOT NULL)"

    { trace_failure_discovery_inputs: [ :corpus_item_id, :corpus_items ],
      trace_failure_discovery_versions: [ :scenario_version_id, :scenario_versions ],
      trace_failure_discovery_cases: [ :eval_case_id, :eval_cases ] }.each do |table, (column, parent)|
      create_table table do |t|
        t.bigint :workspace_id, null: false
        t.bigint :corpus_id, null: false
        t.bigint :trace_failure_discovery_id, null: false
        t.bigint column, null: false
      end
      add_index table, [ :trace_failure_discovery_id, column ], unique: true
      add_foreign_key table, :trace_failure_discoveries, column: [ :workspace_id, :corpus_id, :trace_failure_discovery_id ], primary_key: [ :workspace_id, :corpus_id, :id ], on_delete: :cascade
      add_foreign_key table, parent, column: [ :workspace_id, :corpus_id, column ], primary_key: [ :workspace_id, :corpus_id, :id ], on_delete: :cascade
    end
    add_index :trace_failure_discovery_inputs, [ :workspace_id, :corpus_id, :trace_failure_discovery_id, :corpus_item_id ], unique: true, name: "trace_discovery_input_lineage"

    create_table :trace_failure_discovery_results do |t|
      t.bigint :workspace_id, null: false
      t.bigint :corpus_id, null: false
      t.bigint :trace_failure_discovery_id, null: false
      t.jsonb :result_content, null: false
      t.datetime :created_at, null: false
    end
    add_index :trace_failure_discovery_results, :trace_failure_discovery_id, unique: true
    add_foreign_key :trace_failure_discovery_results, :trace_failure_discoveries, column: [ :workspace_id, :corpus_id, :trace_failure_discovery_id ], primary_key: [ :workspace_id, :corpus_id, :id ], on_delete: :cascade
    add_check_constraint :trace_failure_discovery_results, "jsonb_typeof(result_content) = 'object' AND result_content ? 'decision' AND result_content->>'decision' IN ('proposal', 'abstain', 'error')"
    add_check_constraint :trace_failure_discovery_results, "jsonb_typeof(result_content->'decision') = 'string'"

    create_table :trace_failure_reviews do |t|
      t.bigint :workspace_id, null: false
      t.bigint :corpus_id, null: false
      t.bigint :trace_failure_discovery_id, null: false
      t.bigint :corpus_item_id, null: false
      t.references :reviewed_by, null: false, foreign_key: { to_table: :users }
      t.string :decision, null: false
      t.text :reason, null: false
      t.datetime :created_at, null: false
    end
    add_foreign_key :trace_failure_reviews, :trace_failure_discovery_inputs, column: [ :workspace_id, :corpus_id, :trace_failure_discovery_id, :corpus_item_id ], primary_key: [ :workspace_id, :corpus_id, :trace_failure_discovery_id, :corpus_item_id ], on_delete: :cascade
    add_check_constraint :trace_failure_reviews, "decision IN ('accept', 'reject', 'uncertain') AND length(btrim(reason)) BETWEEN 1 AND 2000"

    reversible do |direction|
      direction.up do
        execute <<~SQL
          CREATE FUNCTION guard_trace_failure_discovery() RETURNS trigger AS $$
          BEGIN
            IF (to_jsonb(NEW) - ARRAY['state', 'error', 'started_at', 'finished_at'])
                IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['state', 'error', 'started_at', 'finished_at'])
              OR NOT ((OLD.state = 'queued' AND NEW.state IN ('running', 'interrupted'))
                OR (OLD.state = 'running' AND NEW.state IN ('complete', 'interrupted'))) THEN
              RAISE EXCEPTION 'trace discovery definition and terminal state are immutable';
            END IF;
            RETURN NEW;
          END;
          $$ LANGUAGE plpgsql;
          CREATE TRIGGER trace_failure_discovery_immutable BEFORE UPDATE ON trace_failure_discoveries FOR EACH ROW EXECUTE FUNCTION guard_trace_failure_discovery();

          CREATE FUNCTION purge_trace_failure_disclosure() RETURNS trigger AS $$
          BEGIN
            IF TG_TABLE_NAME = 'corpus_items' THEN
              DELETE FROM trace_failure_discoveries WHERE id IN (SELECT trace_failure_discovery_id FROM trace_failure_discovery_inputs WHERE corpus_item_id = OLD.id);
            ELSIF TG_TABLE_NAME = 'scenario_versions' THEN
              DELETE FROM trace_failure_discoveries WHERE id IN (SELECT trace_failure_discovery_id FROM trace_failure_discovery_versions WHERE scenario_version_id = OLD.id);
            ELSE
              DELETE FROM trace_failure_discoveries WHERE id IN (SELECT trace_failure_discovery_id FROM trace_failure_discovery_cases WHERE eval_case_id = OLD.id);
            END IF;
            RETURN OLD;
          END;
          $$ LANGUAGE plpgsql;
        SQL
        %w[corpus_items scenario_versions eval_cases].each do |table|
          execute "CREATE TRIGGER #{table}_purge_trace_disclosure BEFORE DELETE ON #{table} FOR EACH ROW EXECUTE FUNCTION purge_trace_failure_disclosure()"
        end
        %w[trace_failure_discovery_inputs trace_failure_discovery_versions trace_failure_discovery_cases trace_failure_discovery_results trace_failure_reviews].each do |table|
          execute "CREATE TRIGGER #{table}_immutable BEFORE UPDATE ON #{table} FOR EACH ROW EXECUTE FUNCTION prevent_lab_version_update()"
        end
      end
      direction.down do
        %w[trace_failure_discovery_inputs trace_failure_discovery_versions trace_failure_discovery_cases trace_failure_discovery_results trace_failure_reviews].each { |table| execute "DROP TRIGGER #{table}_immutable ON #{table}" }
        %w[corpus_items scenario_versions eval_cases].each { |table| execute "DROP TRIGGER #{table}_purge_trace_disclosure ON #{table}" }
        execute "DROP FUNCTION purge_trace_failure_disclosure()"
        execute "DROP TRIGGER trace_failure_discovery_immutable ON trace_failure_discoveries"
        execute "DROP FUNCTION guard_trace_failure_discovery()"
      end
    end
  end
end
