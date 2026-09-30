class CreateEvaluationRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :evaluation_targets do |t|
      t.bigint :workspace_id, null: false
      t.bigint :corpus_id, null: false
      t.string :name, null: false
      t.bigint :current_version_id
      t.timestamps
    end
    add_index :evaluation_targets, [ :workspace_id, :corpus_id, :id ], unique: true
    add_foreign_key :evaluation_targets, :corpora, column: [ :workspace_id, :corpus_id ], primary_key: [ :workspace_id, :id ], on_delete: :cascade

    create_table :evaluation_target_versions do |t|
      t.bigint :workspace_id, null: false
      t.bigint :corpus_id, null: false
      t.bigint :evaluation_target_id, null: false
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.integer :number, null: false
      t.string :adapter, null: false
      t.string :processing_version, null: false
      t.jsonb :configuration, null: false
      t.datetime :created_at, null: false
    end
    add_index :evaluation_target_versions, [ :evaluation_target_id, :number ], unique: true
    add_index :evaluation_target_versions, [ :workspace_id, :corpus_id, :id ], unique: true
    add_index :evaluation_target_versions, [ :workspace_id, :corpus_id, :evaluation_target_id, :id ], unique: true
    add_foreign_key :evaluation_target_versions, :evaluation_targets, column: [ :workspace_id, :corpus_id, :evaluation_target_id ], primary_key: [ :workspace_id, :corpus_id, :id ], on_delete: :cascade
    add_foreign_key :evaluation_targets, :evaluation_target_versions, column: [ :workspace_id, :corpus_id, :id, :current_version_id ], primary_key: [ :workspace_id, :corpus_id, :evaluation_target_id, :id ], on_delete: :cascade
    add_check_constraint :evaluation_target_versions, "number > 0 AND adapter = 'scripted' AND jsonb_typeof(configuration) = 'object'"

    create_table :evaluation_runs do |t|
      t.bigint :workspace_id, null: false
      t.bigint :corpus_id, null: false
      t.bigint :eval_suite_id, null: false
      t.bigint :evaluation_target_version_id, null: false
      t.references :requested_by, null: false, foreign_key: { to_table: :users }
      t.string :processing_version, null: false
      t.string :state, null: false, default: "queued"
      t.text :error
      t.datetime :started_at
      t.datetime :finished_at
      t.datetime :created_at, null: false
    end
    add_index :evaluation_runs, [ :workspace_id, :corpus_id, :id ], unique: true
    add_foreign_key :evaluation_runs, :eval_suites, column: [ :workspace_id, :corpus_id, :eval_suite_id ], primary_key: [ :workspace_id, :corpus_id, :id ], on_delete: :cascade
    add_foreign_key :evaluation_runs, :evaluation_target_versions, column: [ :workspace_id, :corpus_id, :evaluation_target_version_id ], primary_key: [ :workspace_id, :corpus_id, :id ], on_delete: :cascade
    add_check_constraint :evaluation_runs, "state IN ('queued', 'running', 'complete', 'interrupted')"

    create_table :evaluation_run_items do |t|
      t.bigint :workspace_id, null: false
      t.bigint :corpus_id, null: false
      t.bigint :evaluation_run_id, null: false
      t.bigint :eval_case_id, null: false
      t.jsonb :target_input, null: false
    end
    add_index :evaluation_run_items, [ :evaluation_run_id, :eval_case_id ], unique: true
    add_index :evaluation_run_items, [ :workspace_id, :corpus_id, :id, :eval_case_id ], unique: true
    add_foreign_key :evaluation_run_items, :evaluation_runs, column: [ :workspace_id, :corpus_id, :evaluation_run_id ], primary_key: [ :workspace_id, :corpus_id, :id ], on_delete: :cascade
    add_foreign_key :evaluation_run_items, :eval_cases, column: [ :workspace_id, :corpus_id, :eval_case_id ], primary_key: [ :workspace_id, :corpus_id, :id ], on_delete: :cascade
    add_check_constraint :evaluation_run_items, "jsonb_typeof(target_input) = 'object'"

    create_table :evaluation_results do |t|
      t.bigint :workspace_id, null: false
      t.bigint :corpus_id, null: false
      t.bigint :evaluation_run_item_id, null: false
      t.bigint :eval_case_id, null: false
      t.string :status, null: false
      t.jsonb :output
      t.jsonb :decisions, null: false, default: []
      t.text :error
      t.datetime :created_at, null: false
    end
    add_index :evaluation_results, :evaluation_run_item_id, unique: true
    add_index :evaluation_results, [ :workspace_id, :corpus_id, :id, :eval_case_id ], unique: true
    add_foreign_key :evaluation_results, :evaluation_run_items, column: [ :workspace_id, :corpus_id, :evaluation_run_item_id, :eval_case_id ], primary_key: [ :workspace_id, :corpus_id, :id, :eval_case_id ], on_delete: :cascade
    add_check_constraint :evaluation_results, "status IN ('pass', 'fail', 'incomplete', 'error') AND jsonb_typeof(decisions) = 'array'"

    create_table :regression_cases do |t|
      t.bigint :workspace_id, null: false
      t.bigint :corpus_id, null: false
      t.bigint :eval_suite_id, null: false
      t.bigint :eval_case_id, null: false
      t.bigint :evaluation_result_id, null: false
      t.references :reviewed_by, null: false, foreign_key: { to_table: :users }
      t.text :rationale, null: false
      t.datetime :created_at, null: false
    end
    add_index :regression_cases, [ :eval_suite_id, :evaluation_result_id ], unique: true
    add_foreign_key :regression_cases, :eval_suites, column: [ :workspace_id, :corpus_id, :eval_suite_id ], primary_key: [ :workspace_id, :corpus_id, :id ], on_delete: :cascade
    add_foreign_key :regression_cases, :evaluation_results, column: [ :workspace_id, :corpus_id, :evaluation_result_id, :eval_case_id ], primary_key: [ :workspace_id, :corpus_id, :id, :eval_case_id ], on_delete: :cascade
    add_check_constraint :regression_cases, "length(rationale) BETWEEN 1 AND 2000"

    reversible do |direction|
      direction.up do
        %w[evaluation_target_versions evaluation_run_items evaluation_results regression_cases].each { |table| execute "CREATE TRIGGER #{table}_immutable BEFORE UPDATE ON #{table} FOR EACH ROW EXECUTE FUNCTION prevent_lab_version_update()" }
        execute <<~SQL
          CREATE FUNCTION prevent_evaluation_run_rebind() RETURNS trigger AS $$
          BEGIN
            IF ROW(NEW.workspace_id, NEW.corpus_id, NEW.eval_suite_id, NEW.evaluation_target_version_id, NEW.requested_by_id, NEW.processing_version, NEW.created_at)
               IS DISTINCT FROM ROW(OLD.workspace_id, OLD.corpus_id, OLD.eval_suite_id, OLD.evaluation_target_version_id, OLD.requested_by_id, OLD.processing_version, OLD.created_at) THEN
              RAISE EXCEPTION 'evaluation run definition is immutable';
            END IF;
            RETURN NEW;
          END;
          $$ LANGUAGE plpgsql;
          CREATE TRIGGER evaluation_run_definition_immutable BEFORE UPDATE ON evaluation_runs FOR EACH ROW EXECUTE FUNCTION prevent_evaluation_run_rebind();
        SQL
      end
      direction.down do
        execute "DROP TRIGGER evaluation_run_definition_immutable ON evaluation_runs"
        execute "DROP FUNCTION prevent_evaluation_run_rebind()"
        %w[evaluation_target_versions evaluation_run_items evaluation_results regression_cases].each { |table| execute "DROP TRIGGER #{table}_immutable ON #{table}" }
      end
    end
  end
end
