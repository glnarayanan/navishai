class AddRecordedEvaluationTargets < ActiveRecord::Migration[8.1]
  def change
    add_column :evaluation_target_versions, :trace_item_id, :bigint
    add_index :evaluation_target_versions, :trace_item_id
    add_foreign_key :evaluation_target_versions, :corpus_items, column: [ :workspace_id, :corpus_id, :trace_item_id ], primary_key: [ :workspace_id, :corpus_id, :id ], on_delete: :cascade
    remove_check_constraint :evaluation_target_versions, "number > 0 AND adapter IN ('scripted', 'http') AND jsonb_typeof(configuration) = 'object'"
    add_check_constraint :evaluation_target_versions, "number > 0 AND adapter IN ('scripted', 'http', 'recorded') AND jsonb_typeof(configuration) = 'object'"
    add_check_constraint :evaluation_target_versions, "(adapter = 'recorded') = (trace_item_id IS NOT NULL) AND (adapter <> 'recorded' OR configuration = '{}'::jsonb)"
  end
end
