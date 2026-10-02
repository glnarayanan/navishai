class CreateCalibration < ActiveRecord::Migration[8.1]
  def change
    create_table :calibration_sets do |t|
      t.bigint :workspace_id, null: false
      t.bigint :corpus_id, null: false
      t.bigint :grader_version_id, null: false
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.string :name, null: false
      t.datetime :created_at, null: false
    end
    add_index :calibration_sets, [ :workspace_id, :corpus_id, :id, :grader_version_id ], unique: true
    add_foreign_key :calibration_sets, :grader_versions, column: [ :workspace_id, :corpus_id, :grader_version_id ], primary_key: [ :workspace_id, :corpus_id, :id ], on_delete: :cascade
    add_index :eval_case_checks, [ :workspace_id, :corpus_id, :id, :grader_version_id ], unique: true

    create_table :calibration_samples do |t|
      t.bigint :workspace_id, null: false
      t.bigint :corpus_id, null: false
      t.bigint :calibration_set_id, null: false
      t.bigint :grader_version_id, null: false
      t.bigint :eval_case_check_id, null: false
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.string :cohort, null: false
      t.string :output_digest, null: false
      t.jsonb :output, null: false
      t.datetime :created_at, null: false
    end
    add_index :calibration_samples, [ :calibration_set_id, :eval_case_check_id, :output_digest ], unique: true, name: "calibration_sample_identity"
    add_index :calibration_samples, [ :workspace_id, :corpus_id, :id ], unique: true
    add_foreign_key :calibration_samples, :calibration_sets, column: [ :workspace_id, :corpus_id, :calibration_set_id, :grader_version_id ], primary_key: [ :workspace_id, :corpus_id, :id, :grader_version_id ], on_delete: :cascade
    add_foreign_key :calibration_samples, :eval_case_checks, column: [ :workspace_id, :corpus_id, :eval_case_check_id, :grader_version_id ], primary_key: [ :workspace_id, :corpus_id, :id, :grader_version_id ], on_delete: :cascade
    add_check_constraint :calibration_samples, "cohort IN ('development', 'held_out') AND jsonb_typeof(output) = 'object'"

    create_table :calibration_predictions do |t|
      t.bigint :workspace_id, null: false
      t.bigint :corpus_id, null: false
      t.bigint :calibration_sample_id, null: false
      t.jsonb :result, null: false
      t.string :processing_version, null: false
      t.datetime :created_at, null: false
    end
    add_index :calibration_predictions, :calibration_sample_id, unique: true
    add_foreign_key :calibration_predictions, :calibration_samples, column: [ :workspace_id, :corpus_id, :calibration_sample_id ], primary_key: [ :workspace_id, :corpus_id, :id ], on_delete: :cascade
    add_check_constraint :calibration_predictions, "jsonb_typeof(result) = 'object' AND result->>'decision' IN ('pass', 'fail', 'abstain', 'error')"

    create_table :human_labels do |t|
      t.bigint :workspace_id, null: false
      t.bigint :corpus_id, null: false
      t.bigint :calibration_sample_id, null: false
      t.references :labelled_by, null: false, foreign_key: { to_table: :users }
      t.string :decision, null: false
      t.text :rationale, null: false
      t.datetime :created_at, null: false
    end
    add_index :human_labels, [ :calibration_sample_id, :labelled_by_id, :id ]
    add_foreign_key :human_labels, :calibration_samples, column: [ :workspace_id, :corpus_id, :calibration_sample_id ], primary_key: [ :workspace_id, :corpus_id, :id ], on_delete: :cascade
    add_check_constraint :human_labels, "decision IN ('pass', 'fail', 'uncertain') AND length(rationale) BETWEEN 1 AND 2000"

    reversible do |direction|
      direction.up do
        %w[calibration_sets calibration_samples calibration_predictions human_labels].each { |table| execute "CREATE TRIGGER #{table}_immutable BEFORE UPDATE ON #{table} FOR EACH ROW EXECUTE FUNCTION prevent_lab_version_update()" }
      end
      direction.down do
        %w[calibration_sets calibration_samples calibration_predictions human_labels].each { |table| execute "DROP TRIGGER #{table}_immutable ON #{table}" }
      end
    end
  end
end
