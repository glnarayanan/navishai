require "test_helper"
require "open3"

class ProductionEnvironmentTest < ActiveSupport::TestCase
  test "boots with deployment SMTP configured for required TLS" do
    script = <<~RUBY
      settings = Rails.application.config.action_mailer.smtp_settings
      puts "SYSTEM_MAIL_SMTP_RESULT=\#{JSON.generate(method: Rails.application.config.action_mailer.delivery_method, settings: settings.slice(:address, :port, :enable_starttls, :enable_starttls_auto, :openssl_verify_mode))}"
    RUBY
    output, status = Open3.capture2e(
      {
        "RAILS_ENV" => "production", "NAVISHAI_APP_HOST" => "app.example.test", "SECRET_KEY_BASE" => "s" * 64,
        "NAVISHAI_SYSTEM_SMTP_ADDRESS" => "127.0.0.1", "NAVISHAI_SYSTEM_SMTP_PORT" => "587",
        "NAVISHAI_SYSTEM_SMTP_USER_NAME" => "test", "NAVISHAI_SYSTEM_SMTP_PASSWORD" => "test"
      }, Rails.root.join("bin/rails").to_s, "runner", script
    )
    assert status.success?, output
    result = JSON.parse(output.lines.grep(/SYSTEM_MAIL_SMTP_RESULT=/).sole.split("=", 2).last)
    assert_equal "smtp", result.fetch("method")
    assert_equal({ "address" => "127.0.0.1", "port" => 587, "enable_starttls" => true, "enable_starttls_auto" => false, "openssl_verify_mode" => "peer" }, result.fetch("settings"))
  end

  test "boots without deployment SMTP and rejects system-mail delivery" do
    script = <<~RUBY
      result = { delivery_method: Rails.application.config.action_mailer.delivery_method }
      begin
        mail = ApplicationMailer.new.mail(to: "admin@example.test", from: "no-reply@app.example.test", subject: "test", body: "private body")
        mail.deliver!
      rescue => error
        result[:error] = error.message
      end
      puts "SYSTEM_MAIL_TEST_RESULT=\#{JSON.generate(result)}"
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
    result = JSON.parse(output.lines.grep(/SYSTEM_MAIL_TEST_RESULT=/).sole.split("=", 2).last)
    assert_equal "system_mail_unavailable", result.fetch("delivery_method")
    assert_includes result.fetch("error"), "System mail is unavailable"
    assert_not_includes result.fetch("error"), "private body"
  end

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
