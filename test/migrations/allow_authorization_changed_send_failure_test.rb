require "test_helper"
require Rails.root.join("db/migrate/20260826123000_allow_authorization_changed_send_failure")

class AllowAuthorizationChangedSendFailureTest < ActiveSupport::TestCase
  test "down restores the prior failure constraint and up reapplies the new constraint" do
    migration = AllowAuthorizationChangedSendFailure.new

    migration.migrate(:down)
    refute_includes failure_expression, "authorization_changed"

    migration.migrate(:up)
    assert_includes failure_expression, "authorization_changed"
  ensure
    migration&.migrate(:up) unless failure_expression&.include?("authorization_changed")
  end

  private
    def failure_expression
      ActiveRecord::Base.connection.check_constraints(:intercom_outbound_deliveries)
        .find { |constraint| constraint.name == "intercom_outbound_deliveries_failure" }&.expression
    end
end
