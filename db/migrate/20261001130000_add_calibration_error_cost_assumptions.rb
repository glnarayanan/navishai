class AddCalibrationErrorCostAssumptions < ActiveRecord::Migration[8.1]
  def change
    # A numeric typmod would round before CHECK can reject excess precision.
    add_column :calibration_sets, :false_positive_cost, :decimal
    add_column :calibration_sets, :false_negative_cost, :decimal
    add_column :calibration_sets, :error_cost_unit, :text
    add_column :calibration_sets, :error_cost_rationale, :text
    add_check_constraint :calibration_sets, <<~SQL, name: "calibration_error_cost_group"
      (false_positive_cost IS NULL AND false_negative_cost IS NULL AND error_cost_unit IS NULL AND error_cost_rationale IS NULL)
      OR
      (false_positive_cost IS NOT NULL AND false_negative_cost IS NOT NULL AND error_cost_unit IS NOT NULL AND error_cost_rationale IS NOT NULL
       AND false_positive_cost >= 0 AND false_positive_cost < 1000000000000
       AND false_negative_cost >= 0 AND false_negative_cost < 1000000000000
       AND scale(false_positive_cost) <= 6 AND scale(false_negative_cost) <= 6
       AND char_length(error_cost_unit) BETWEEN 1 AND 120 AND error_cost_unit ~ '[^[:space:]]'
       AND char_length(error_cost_rationale) BETWEEN 1 AND 2000 AND error_cost_rationale ~ '[^[:space:]]')
    SQL
  end
end
