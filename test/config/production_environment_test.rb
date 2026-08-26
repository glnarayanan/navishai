require "test_helper"
require "open3"

class ProductionEnvironmentTest < ActiveSupport::TestCase
  test "rejects an unconfigured Host header" do
    script = <<~RUBY
      statuses = {
        unconfigured: Rails.application.call(Rack::MockRequest.env_for("/session/new", "HTTPS" => "on", "HTTP_HOST" => "attacker.example")).first,
        configured: Rails.application.call(Rack::MockRequest.env_for("/session/new", "HTTPS" => "on", "HTTP_HOST" => "app.example.test")).first,
        health: Rails.application.call(Rack::MockRequest.env_for("/up", "HTTPS" => "on", "HTTP_HOST" => "attacker.example")).first
      }
      puts "HOST_TEST_RESULT=\#{JSON.generate(statuses)}"
    RUBY
    output, status = Open3.capture2e(
      {
        "RAILS_ENV" => "production",
        "NAVISHAI_APP_HOST" => "app.example.test",
        "SECRET_KEY_BASE" => "s" * 64
      },
      Rails.root.join("bin/rails").to_s, "runner", script
    )

    assert status.success?, output
    result = JSON.parse(output.lines.grep(/HOST_TEST_RESULT=/).sole.split("=", 2).last)
    assert_equal({ "unconfigured" => 403, "configured" => 200, "health" => 200 }, result)
  end
end
