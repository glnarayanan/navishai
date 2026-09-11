require "test_helper"
require "openssl"
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

  test "SMTP delivery uses trusted STARTTLS before authentication" do
    certificate, private_key = smtp_certificate
    OpenSSL::SSL::SSLContext::DEFAULT_CERT_STORE.add_cert(certificate)
    server = TCPServer.new("127.0.0.1", 0)
    commands = Queue.new
    thread = Thread.new do
      socket = server.accept
      socket.write("220 fake SMTP\r\n")
      commands << socket.gets
      socket.write("250-fake SMTP\r\n250-STARTTLS\r\n250 AUTH PLAIN\r\n")
      commands << socket.gets
      socket.write("220 Ready to start TLS\r\n")

      context = OpenSSL::SSL::SSLContext.new
      context.cert = certificate
      context.key = private_key
      client = OpenSSL::SSL::SSLSocket.new(socket, context)
      client.accept
      commands << client.gets
      client.write("250-fake SMTP\r\n250 AUTH PLAIN\r\n")
      commands << client.gets
      client.write("235 Authentication successful\r\n")
      commands << client.gets
      client.write("250 Sender accepted\r\n")
      commands << client.gets
      client.write("250 Recipient accepted\r\n")
      commands << client.gets
      client.write("354 Send message data\r\n")
      while (line = client.gets)
        break if line == ".\r\n"
      end
      client.write("250 Message accepted\r\n")
      commands << client.gets
      client.write("221 Closing connection\r\n")
    rescue IOError, Errno::ECONNRESET, OpenSSL::SSL::SSLError
      nil
    ensure
      client&.close
      socket&.close
    end

    settings = SystemMailConfiguration.smtp_settings(
      "NAVISHAI_SYSTEM_SMTP_ADDRESS" => "127.0.0.1", "NAVISHAI_SYSTEM_SMTP_PORT" => server.addr[1].to_s,
      "NAVISHAI_SYSTEM_SMTP_USER_NAME" => "admin", "NAVISHAI_SYSTEM_SMTP_PASSWORD" => "secret", "NAVISHAI_SYSTEM_SMTP_FROM" => "admin@example.test"
    )
    delivered = Mail::SMTP.new(settings).deliver!(Mail.new(to: "admin@example.test", from: "admin@example.test", subject: "test", body: "private"))

    assert_instance_of Mail::SMTP, delivered
    observed = []
    observed << commands.pop until commands.empty?
    assert_match(/\AEHLO /, observed.first)
    assert_equal "STARTTLS\r\n", observed.second
    assert_match(/\AEHLO /, observed.third)
    assert_match(/\AAUTH PLAIN/, observed.fourth)
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

  private

  def smtp_certificate
    private_key = OpenSSL::PKey::RSA.new(2048)
    certificate = OpenSSL::X509::Certificate.new
    certificate.version = 2
    certificate.serial = 1
    certificate.subject = OpenSSL::X509::Name.parse("CN=127.0.0.1")
    certificate.issuer = certificate.subject
    certificate.public_key = private_key.public_key
    certificate.not_before = Time.now - 60
    certificate.not_after = Time.now + 3600
    extensions = OpenSSL::X509::ExtensionFactory.new
    extensions.subject_certificate = certificate
    extensions.issuer_certificate = certificate
    certificate.add_extension(extensions.create_extension("basicConstraints", "CA:TRUE", true))
    certificate.add_extension(extensions.create_extension("subjectAltName", "IP:127.0.0.1"))
    certificate.sign(private_key, OpenSSL::Digest::SHA256.new)
    [ certificate, private_key ]
  end
end
