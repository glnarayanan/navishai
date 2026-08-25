require "test_helper"

class HealthCheckTest < ActionDispatch::IntegrationTest
  test "reports that the control plane is live" do
    get rails_health_check_path

    assert_response :success
  end
end
