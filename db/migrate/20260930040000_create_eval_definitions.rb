class CreateEvalDefinitions < ActiveRecord::Migration[8.1]
  def change
    create_table :graders do |t|
      t.bigint :workspace_id, null: false
      t.bigint :corpus_id, null: false
      t.string :name, null: false
      t.bigint :current_version_id
      t.timestamps
    end
    add_index :graders, [ :workspace_id, :corpus_id, :id ], unique: true
    add_foreign_key :graders, :corpora, column: [ :workspace_id, :corpus_id ], primary_key: [ :workspace_id, :id ], on_delete: :cascade

    create_table :grader_versions do |t|
      t.bigint :workspace_id, null: false
      t.bigint :corpus_id, null: false
      t.bigint :grader_id, null: false
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.integer :number, null: false
      t.string :kind, null: false
      t.string :processing_version, null: false
      t.jsonb :definition, null: false
      t.datetime :created_at, null: false
    end
    add_index :grader_versions, [ :grader_id, :number ], unique: true
    add_index :grader_versions, [ :workspace_id, :corpus_id, :id ], unique: true
    add_index :grader_versions, [ :workspace_id, :corpus_id, :grader_id, :id ], unique: true
    add_foreign_key :grader_versions, :graders, column: [ :workspace_id, :corpus_id, :grader_id ], primary_key: [ :workspace_id, :corpus_id, :id ], on_delete: :cascade
    add_foreign_key :graders, :grader_versions, column: [ :workspace_id, :corpus_id, :id, :current_version_id ], primary_key: [ :workspace_id, :corpus_id, :grader_id, :id ], on_delete: :cascade
    add_check_constraint :grader_versions, "number > 0 AND kind IN ('deterministic', 'rubric_judge') AND jsonb_typeof(definition) = 'object'"

    create_table :eval_cases do |t|
      t.bigint :workspace_id, null: false
      t.bigint :corpus_id, null: false
      t.bigint :scenario_version_id, null: false
      t.bigint :scenario_review_id, null: false
      t.references :compiled_by, null: false, foreign_key: { to_table: :users }
      t.integer :number, null: false
      t.string :compiler_version, null: false
      t.string :definition_digest, null: false
      t.jsonb :contract, null: false
      t.datetime :created_at, null: false
    end
    add_index :eval_cases, [ :scenario_version_id, :number ], unique: true
    add_index :eval_cases, [ :scenario_version_id, :definition_digest ], unique: true
    add_index :eval_cases, [ :workspace_id, :corpus_id, :id ], unique: true
    add_index :eval_cases, [ :workspace_id, :corpus_id, :id, :scenario_version_id ], unique: true
    add_index :scenario_reviews, [ :workspace_id, :corpus_id, :scenario_version_id, :id ], unique: true
    add_foreign_key :eval_cases, :scenario_versions, column: [ :workspace_id, :corpus_id, :scenario_version_id ], primary_key: [ :workspace_id, :corpus_id, :id ], on_delete: :cascade
    add_foreign_key :eval_cases, :scenario_reviews, column: [ :workspace_id, :corpus_id, :scenario_version_id, :scenario_review_id ], primary_key: [ :workspace_id, :corpus_id, :scenario_version_id, :id ], on_delete: :cascade
    add_check_constraint :eval_cases, "number > 0 AND jsonb_typeof(contract) = 'object'"

    create_table :eval_case_checks do |t|
      t.bigint :workspace_id, null: false
      t.bigint :corpus_id, null: false
      t.bigint :eval_case_id, null: false
      t.bigint :scenario_version_id, null: false
      t.bigint :scenario_evidence_id, null: false
      t.bigint :grader_version_id, null: false
      t.string :requirement_kind, null: false
      t.integer :requirement_index, null: false
    end
    add_index :eval_case_checks, [ :eval_case_id, :requirement_kind, :requirement_index ], unique: true
    add_index :eval_case_checks, [ :workspace_id, :corpus_id, :id ], unique: true
    add_index :scenario_evidence, [ :workspace_id, :corpus_id, :scenario_version_id, :id ], unique: true
    add_foreign_key :eval_case_checks, :eval_cases, column: [ :workspace_id, :corpus_id, :eval_case_id, :scenario_version_id ], primary_key: [ :workspace_id, :corpus_id, :id, :scenario_version_id ], on_delete: :cascade
    add_foreign_key :eval_case_checks, :scenario_evidence, column: [ :workspace_id, :corpus_id, :scenario_version_id, :scenario_evidence_id ], primary_key: [ :workspace_id, :corpus_id, :scenario_version_id, :id ], on_delete: :cascade
    add_foreign_key :eval_case_checks, :grader_versions, column: [ :workspace_id, :corpus_id, :grader_version_id ], primary_key: [ :workspace_id, :corpus_id, :id ], on_delete: :cascade
    add_check_constraint :eval_case_checks, "requirement_kind IN ('outcomes', 'actions', 'forbidden', 'escalation', 'grounding') AND requirement_index BETWEEN 0 AND 19"

    create_table :eval_suites do |t|
      t.bigint :workspace_id, null: false
      t.bigint :corpus_id, null: false
      t.string :name, null: false
      t.string :kind, null: false, default: "evaluation"
      t.timestamps
    end
    add_index :eval_suites, [ :workspace_id, :corpus_id, :id ], unique: true
    add_foreign_key :eval_suites, :corpora, column: [ :workspace_id, :corpus_id ], primary_key: [ :workspace_id, :id ], on_delete: :cascade
    add_check_constraint :eval_suites, "kind IN ('evaluation', 'regression')"

    create_table :eval_suite_cases do |t|
      t.bigint :workspace_id, null: false
      t.bigint :corpus_id, null: false
      t.bigint :eval_suite_id, null: false
      t.bigint :eval_case_id, null: false
    end
    add_index :eval_suite_cases, [ :eval_suite_id, :eval_case_id ], unique: true
    add_foreign_key :eval_suite_cases, :eval_suites, column: [ :workspace_id, :corpus_id, :eval_suite_id ], primary_key: [ :workspace_id, :corpus_id, :id ], on_delete: :cascade
    add_foreign_key :eval_suite_cases, :eval_cases, column: [ :workspace_id, :corpus_id, :eval_case_id ], primary_key: [ :workspace_id, :corpus_id, :id ], on_delete: :cascade
    reversible do |direction|
      direction.up do
        %w[grader_versions eval_cases eval_case_checks].each { |table| execute "CREATE TRIGGER #{table}_immutable BEFORE UPDATE ON #{table} FOR EACH ROW EXECUTE FUNCTION prevent_lab_version_update()" }
      end
      direction.down do
        %w[grader_versions eval_cases eval_case_checks].each { |table| execute "DROP TRIGGER #{table}_immutable ON #{table}" }
      end
    end
  end
end
