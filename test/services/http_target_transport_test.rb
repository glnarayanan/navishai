require "test_helper"
require "socket"
require_relative "../test_helpers/eval_test_helper"
require_relative "../test_helpers/http_target_test_helper"

class HttpTargetTransportTest < ActiveSupport::TestCase
  include EvalTestHelper
  include HttpTargetTestHelper

  test "real local TLS verifies hostname and trust streams JSON and sends one isolated request" do
    output = support_output(tools: [ "collect_expiry" ])
    input = { "situation" => "SAML error", "known_facts" => { "plan" => "enterprise" }, "knowledge" => [] }
    response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n#{output.to_json.bytesize.to_s(16)}\r\n#{output.to_json}\r\n0\r\n\r\n"
    with_local_tls(response:) do |requests|
      with_endpoint_approval(workspace_id: 17) do
        assert_equal output, HttpTarget.call(configuration: { "endpoint" => HTTP_ENDPOINT }, input:, workspace_id: 17, request_key: "tls-key")
      end
      request = requests.pop
      assert_equal "POST /evaluate HTTP/1.1", request.fetch(:line)
      assert_equal "Bearer test-only-token", request.fetch(:headers).fetch("authorization")
      assert_equal "tls-key", request.fetch(:headers).fetch("idempotency-key")
      assert_equal({ "schema" => "support-target-v1", "input" => input }, JSON.parse(request.fetch(:body)))
    end
  end

  test "actual TLS rejects the wrong hostname and never follows a redirect to metadata" do
    with_local_tls(response: "", certificate_host: "another.example.test") do |_requests|
      with_endpoint_approval(workspace_id: 17) do
        assert_raises(HttpTarget::Error) { HttpTarget.call(configuration: { "endpoint" => HTTP_ENDPOINT }, input: {}, workspace_id: 17, request_key: "wrong-host") }
      end
    end
    with_local_tls(response: "HTTP/1.1 302 Found\r\nLocation: http://169.254.169.254/secret\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") do |requests|
      with_endpoint_approval(workspace_id: 17) do
        error = assert_raises(HttpTarget::Error) { HttpTarget.call(configuration: { "endpoint" => HTTP_ENDPOINT }, input: {}, workspace_id: 17, request_key: "redirect") }
        assert_includes error.message, "Redirects are not followed"
      end
      assert_equal "redirect", requests.pop.fetch(:headers).fetch("idempotency-key")
      assert requests.empty?
    end
  end

  private
    # Only the test socket is rerouted to loopback. Production still checks all
    # DNS answers and pins a public address with hostname verification enabled.
    def with_local_tls(response:, certificate_host: "eval.example.test")
      key = OpenSSL::PKey::RSA.new(2048)
      certificate = OpenSSL::X509::Certificate.new
      certificate.version = 2
      certificate.serial = 1
      certificate.subject = certificate.issuer = OpenSSL::X509::Name.parse("CN=#{certificate_host}")
      certificate.public_key = key.public_key
      certificate.not_before = Time.now - 60
      certificate.not_after = Time.now + 3600
      extensions = OpenSSL::X509::ExtensionFactory.new
      extensions.subject_certificate = extensions.issuer_certificate = certificate
      certificate.add_extension(extensions.create_extension("subjectAltName", "DNS:#{certificate_host}"))
      certificate.sign(key, OpenSSL::Digest::SHA256.new)
      context = OpenSSL::SSL::SSLContext.new
      context.cert = certificate
      context.key = key
      tcp = TCPServer.new("127.0.0.1", 0)
      server = OpenSSL::SSL::SSLServer.new(tcp, context)
      requests = Queue.new
      worker = Thread.new do
        socket = nil
        Timeout.timeout(5) do
          socket = server.accept
          line = socket.gets.strip
          headers = {}
          while (header = socket.gets) && header != "\r\n"
            name, value = header.split(":", 2)
            headers[name.downcase] = value.strip
          end
          requests << { line:, headers:, body: socket.read(headers.fetch("content-length").to_i) }
          socket.write(response)
        end
      rescue OpenSSL::SSL::SSLError
        # A rejected test certificate closes the handshake before HTTP exists.
      ensure
        socket&.close
      end
      store = OpenSSL::X509::Store.new
      store.add_cert(certificate)
      original_connection = EvaluationHttp.method(:connection)
      with_test_method(Resolv, :getaddresses, ->(*) { [ "93.184.216.34" ] }) do
        with_test_method(EvaluationHttp, :connection, ->(uri, address) {
          assert_equal "93.184.216.34", address
          local_uri = uri.dup
          local_uri.port = tcp.addr[1]
          original_connection.call(local_uri, "127.0.0.1").tap { |http| http.cert_store = store }
        }) { yield requests }
      end
    ensure
      tcp&.close
      worker&.value
    end
end
