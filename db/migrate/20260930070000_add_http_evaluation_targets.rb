class AddHttpEvaluationTargets < ActiveRecord::Migration[8.1]
  def change
    remove_check_constraint :evaluation_target_versions, "number > 0 AND adapter = 'scripted' AND jsonb_typeof(configuration) = 'object'"
    add_check_constraint :evaluation_target_versions, "number > 0 AND adapter IN ('scripted', 'http') AND jsonb_typeof(configuration) = 'object'"
    add_column :evaluation_run_items, :request_key, :uuid, null: false, default: -> { "gen_random_uuid()" }
    add_index :evaluation_run_items, :request_key, unique: true
    add_column :evaluation_results, :execution, :jsonb, null: false, default: {}
    add_check_constraint :evaluation_results, "jsonb_typeof(execution) = 'object'"
  end
end
