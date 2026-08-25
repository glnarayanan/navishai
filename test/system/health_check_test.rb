require "application_system_test_case"

class HealthCheckTest < ApplicationSystemTestCase
  test "loads the control plane in a browser" do
    visit rails_health_check_path

    assert_selector "body[style='background-color: green']"
  end
end
