class BindCalibrationSamplesToSavedResults < ActiveRecord::Migration[8.1]
  def up
    add_column :calibration_samples, :eval_case_id, :bigint
    add_column :calibration_samples, :evaluation_result_id, :bigint
    execute "ALTER TABLE calibration_samples DISABLE TRIGGER calibration_samples_immutable"
    execute "UPDATE calibration_samples SET eval_case_id = eval_case_checks.eval_case_id FROM eval_case_checks WHERE eval_case_checks.id = calibration_samples.eval_case_check_id"
    execute "ALTER TABLE calibration_samples ENABLE TRIGGER calibration_samples_immutable"
    change_column_null :calibration_samples, :eval_case_id, false
    add_index :eval_case_checks, [ :workspace_id, :corpus_id, :id, :eval_case_id ], unique: true, name: "calibration_check_case_identity"
    add_foreign_key :calibration_samples, :eval_case_checks, column: [ :workspace_id, :corpus_id, :eval_case_check_id, :eval_case_id ], primary_key: [ :workspace_id, :corpus_id, :id, :eval_case_id ], on_delete: :cascade, name: "calibration_sample_check_case"
    add_foreign_key :calibration_samples, :evaluation_results, column: [ :workspace_id, :corpus_id, :evaluation_result_id, :eval_case_id ], primary_key: [ :workspace_id, :corpus_id, :id, :eval_case_id ], on_delete: :cascade, name: "calibration_sample_result_case"
  end

  def down
    remove_foreign_key :calibration_samples, name: "calibration_sample_result_case"
    remove_foreign_key :calibration_samples, name: "calibration_sample_check_case"
    remove_index :eval_case_checks, name: "calibration_check_case_identity"
    remove_column :calibration_samples, :evaluation_result_id
    remove_column :calibration_samples, :eval_case_id
  end
end
