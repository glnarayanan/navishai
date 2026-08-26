class AllowAuthorizationChangedSendFailure < ActiveRecord::Migration[8.1]
  def change
    remove_check_constraint :intercom_outbound_deliveries,
      name: "intercom_outbound_deliveries_failure"
    add_check_constraint :intercom_outbound_deliveries,
      "failure_code IS NULL OR failure_code IN ('configuration_error', 'remote_rejected', 'authorization_changed', 'unknown_outcome', 'confirmed_not_sent')",
      name: "intercom_outbound_deliveries_failure"
  end
end
