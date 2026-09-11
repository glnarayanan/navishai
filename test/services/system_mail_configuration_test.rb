require "test_helper"
require "socket"

class SystemMailConfigurationTest < ActiveSupport::TestCase
  test "SMTP delivery rejects a server that omits STARTTLS before authentication" do
    server = TCPServer.new("127.0.0.1", 0)
    commands = Queue.new
    thread = Thread.new do
      client = server.accept
      client.write("220 fake SMTP\r\n")
      commands << client.gets
      client.write("250-fake SMTP\r\n250 AUTH PLAIN\r\n")
      commands << client.gets until client.closed? || client.eof?
    rescue IOError, Errno::ECONNRESET
      nil
    ensure
      client&.close
    end

    settings = SystemMailConfiguration.smtp_settings(
      "NAVISHAI_SYSTEM_SMTP_ADDRESS" => "127.0.0.1", "NAVISHAI_SYSTEM_SMTP_PORT" => server.addr[1].to_s,
      "NAVISHAI_SYSTEM_SMTP_USER_NAME" => "admin", "NAVISHAI_SYSTEM_SMTP_PASSWORD" => "secret", "NAVISHAI_SYSTEM_SMTP_FROM" => "admin@example.test"
    )
    error = assert_raises(Net::SMTPUnsupportedCommand) do
      Mail::SMTP.new(settings).deliver!(Mail.new(to: "admin@example.test", from: "admin@example.test", subject: "test", body: "private"))
    end
    assert_match(/STARTTLS/i, error.message)
    observed = []
    observed << commands.pop until commands.empty?
    refute observed.any? { |command| command&.start_with?("AUTH") }
  ensure
    server&.close
    thread&.join(1)
  end

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
