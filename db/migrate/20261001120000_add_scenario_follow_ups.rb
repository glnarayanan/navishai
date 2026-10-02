class AddScenarioFollowUps < ActiveRecord::Migration[8.1]
  def change
    add_column :scenario_versions, :follow_ups, :jsonb, null: false, default: []
    add_check_constraint :scenario_versions, "jsonb_typeof(follow_ups) = 'array' AND jsonb_array_length(follow_ups) <= 10"
    remove_check_constraint :evaluation_target_versions, "number > 0 AND adapter IN ('scripted', 'http', 'recorded') AND jsonb_typeof(configuration) = 'object'"
    add_check_constraint :evaluation_target_versions, "number > 0 AND adapter IN ('scripted', 'http', 'recorded', 'http_conversation') AND jsonb_typeof(configuration) = 'object'"
  end
end
