class AllowAuthorizationChangedSendFailure < ActiveRecord::Migration[8.1]
  OLD_EXPRESSION = <<~SQL.squish.freeze
    failure_code IS NULL OR failure_code IN
    ('configuration_error', 'remote_rejected', 'unknown_outcome', 'confirmed_not_sent')
  SQL
  NEW_EXPRESSION = <<~SQL.squish.freeze
    failure_code IS NULL OR failure_code IN
    ('configuration_error', 'remote_rejected', 'authorization_changed', 'unknown_outcome', 'confirmed_not_sent')
  SQL

  def up
    replace_constraint(NEW_EXPRESSION)
  end

  def down
    replace_constraint(OLD_EXPRESSION)
  end

  private
    def replace_constraint(expression)
      remove_check_constraint :intercom_outbound_deliveries,
        name: "intercom_outbound_deliveries_failure"
      add_check_constraint :intercom_outbound_deliveries, expression,
        name: "intercom_outbound_deliveries_failure"
    end
end
