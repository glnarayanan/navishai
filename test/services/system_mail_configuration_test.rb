require "test_helper"

class SystemMailConfigurationTest < ActiveSupport::TestCase
  test "distinguishes absent invalid and configured deployment SMTP" do
    assert_equal :skipped, SystemMailConfiguration.status({})
    assert_equal :invalid, SystemMailConfiguration.status("NAVISHAI_SYSTEM_SMTP_PORT" => "70000")

    settings = { "NAVISHAI_SYSTEM_SMTP_ADDRESS" => "smtp.test", "NAVISHAI_SYSTEM_SMTP_PORT" => "587", "NAVISHAI_SYSTEM_SMTP_USER_NAME" => "admin", "NAVISHAI_SYSTEM_SMTP_PASSWORD" => "secret", "NAVISHAI_SYSTEM_SMTP_FROM" => "admin@example.test" }
    assert_equal :configured, SystemMailConfiguration.status(settings)
    smtp = SystemMailConfiguration.smtp_settings(settings)
    assert_equal true, smtp[:enable_starttls]
    assert_equal false, smtp[:enable_starttls_auto]
    assert_equal "peer", smtp[:openssl_verify_mode]
    assert_equal "admin@example.test", SystemMailConfiguration.from_address(settings)
  end

  test "unavailable delivery raises without exposing mail content" do
    error = assert_raises(RuntimeError) { SystemMailUnavailableDelivery.new.deliver!(Object.new) }
    assert_includes error.message, "System mail is unavailable"
  end
end
