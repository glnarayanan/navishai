class AddJudgeExecution < ActiveRecord::Migration[8.1]
  def change
    add_column :evaluation_runs, :judge_disclosure, :boolean, null: false, default: false
    create_table :calibration_judge_runs do |t|
      t.bigint :workspace_id, null: false
      t.bigint :corpus_id, null: false
      t.bigint :calibration_sample_id, null: false
      t.references :requested_by, null: false, foreign_key: { to_table: :users }
      t.uuid :request_key, null: false, default: -> { "gen_random_uuid()" }
      t.string :state, null: false, default: "queued"
      t.text :error
      t.datetime :started_at
      t.datetime :finished_at
      t.datetime :created_at, null: false
    end
    add_index :calibration_judge_runs, :calibration_sample_id, unique: true
    add_index :calibration_judge_runs, :request_key, unique: true
    add_foreign_key :calibration_judge_runs, :calibration_samples, column: [ :workspace_id, :corpus_id, :calibration_sample_id ], primary_key: [ :workspace_id, :corpus_id, :id ], on_delete: :cascade
    add_check_constraint :calibration_judge_runs, "state IN ('queued', 'running', 'complete', 'interrupted')"
    reversible do |direction|
      direction.up do
        execute <<~SQL
          CREATE OR REPLACE FUNCTION prevent_evaluation_run_rebind() RETURNS trigger AS $$
          BEGIN
            IF (to_jsonb(NEW) - ARRAY['state', 'error', 'started_at', 'finished_at'])
               IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['state', 'error', 'started_at', 'finished_at']) THEN
              RAISE EXCEPTION 'evaluation run definition is immutable';
            END IF;
            RETURN NEW;
          END;
          $$ LANGUAGE plpgsql;
          CREATE TRIGGER calibration_judge_run_definition_immutable BEFORE UPDATE ON calibration_judge_runs FOR EACH ROW EXECUTE FUNCTION prevent_evaluation_run_rebind();
        SQL
      end
      direction.down { execute "DROP TRIGGER calibration_judge_run_definition_immutable ON calibration_judge_runs" }
    end
  end
end
