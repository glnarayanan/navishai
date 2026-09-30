require "test_helper"
require_relative "../test_helpers/eval_test_helper"
require_relative "../test_helpers/http_target_test_helper"

class HttpTargetTest < ActiveSupport::TestCase
  include EvalTestHelper
  include HttpTargetTestHelper

  test "endpoint configuration and operator approval are exact per workspace with no secret stored in definitions" do
    with_endpoint_approval(workspace_id: 17) do
      HttpTarget.validate!({ "endpoint" => HTTP_ENDPOINT }, workspace_id: 17)
      assert_raises(HttpTarget::Error) { HttpTarget.validate!({ "endpoint" => HTTP_ENDPOINT }, workspace_id: 18) }
      assert_raises(HttpTarget::Error) { HttpTarget.validate!({ "endpoint" => "#{HTTP_ENDPOINT}/another" }, workspace_id: 17) }
      [ "http://eval.example.test/evaluate", "https://user:secret@eval.example.test/evaluate", "#{HTTP_ENDPOINT}?token=secret", "#{HTTP_ENDPOINT}#fragment", "https://eval.example.test:8443/evaluate", "file:///etc/passwd" ].each do |value|
        assert_raises(SupportOutput::Invalid) { HttpTarget.endpoint(value) }
      end
      assert_raises(SupportOutput::Invalid) { HttpTarget.validate!({ "endpoint" => HTTP_ENDPOINT, "bearer_token" => "secret" }, workspace_id: 17) }
      ENV["NAVISHAI_EVALUATION_ENDPOINTS"] = "{invalid"
      assert_raises(HttpTarget::Error) { HttpTarget.approval!(HTTP_ENDPOINT, workspace_id: 17) }
      ENV["NAVISHAI_EVALUATION_ENDPOINTS"] = [ { workspace_id: 17, endpoint: HTTP_ENDPOINT, bearer_token: "a\r\nInjected: header" } ].to_json
      assert_raises(HttpTarget::Error) { HttpTarget.approval!(HTTP_ENDPOINT, workspace_id: 17) }
    end
  end

  test "public address policy rejects local metadata special use and translated private addresses on both IP families" do
    %w[93.184.216.34 8.8.8.8 2606:4700:4700::1111 2001:4860:4860::8888].each { |address| assert HttpTarget.public_address?(address), address }
    %w[0.1.2.3 10.0.0.1 100.64.0.1 127.0.0.1 169.254.169.254 172.31.255.255 192.0.0.9 192.0.2.10 192.168.1.1 198.18.0.1 198.51.100.9 203.0.113.1 224.0.0.1 240.0.0.1 255.255.255.255 ::1 :: ::ffff:10.0.0.1 ::ffff:8.8.8.8 fc00::1 fe80::1 ff02::1 64:ff9b::a00:1 2001::1 2001:db8::1 2002:a00:1::1 3fff::1 invalid].each { |address| assert_not HttpTarget.public_address?(address), address }
  end

  test "DNS validates all answers each time and binds the single approved address while sending only visible input" do
    input = { "situation" => "SSO broke", "known_facts" => { "admin" => false }, "knowledge" => [] }
    with_endpoint_approval(workspace_id: 17) do
      with_test_method(HttpTarget, :perform, ->(*) { flunk "Unsafe DNS must never reach transport" }) do
        [ [], [ "93.184.216.34", "127.0.0.1" ], [ "::ffff:127.0.0.1" ] ].each do |addresses|
          with_test_method(Resolv, :getaddresses, ->(*) { addresses }) do
            assert_raises(HttpTarget::Error) { call_target(input) }
          end
        end
      end
      calls = []
      expected = support_output(tools: [ "collect_expiry" ])
      with_test_method(HttpTarget, :perform, ->(uri, request, address) { calls << [ uri, request, address ]; expected.to_json }) do
        with_test_method(Resolv, :getaddresses, ->(host) { assert_equal "eval.example.test", host; [ "93.184.216.34", "8.8.8.8" ] }) do
          assert_equal expected, call_target(input)
        end
      end
      uri, request, address = calls.sole
      assert_equal HTTP_ENDPOINT, uri.to_s
      assert_equal "93.184.216.34", address
      assert_equal "POST", request.method
      assert_equal "/evaluate", request.path
      assert_equal({ "schema" => "support-target-v1", "input" => input }, JSON.parse(request.body))
      assert_equal "test-request-key", request["Idempotency-Key"]
      assert_equal "Bearer test-only-token", request["Authorization"]
      assert_equal "identity", request["Accept-Encoding"]
      http = HttpTarget.connection(uri, address)
      assert_equal address, http.ipaddr
      assert_equal "eval.example.test", http.address
      assert_nil http.proxy_address
      assert http.use_ssl?
      assert http.verify_hostname
      assert_equal OpenSSL::SSL::VERIFY_PEER, http.verify_mode
      assert_equal 0, http.max_retries
      assert_equal [ 5, 10, 10 ], [ http.open_timeout, http.read_timeout, http.write_timeout ]
    end
  end

  test "bounded responses refuse redirect error compression declared or streamed oversize and invalid UTF8" do
    [ [ 302, {}, [ "redirect" ] ], [ 503, {}, [ "private error" ] ], [ 200, { "content-type" => "text/html" }, [ "html" ] ],
      [ 200, { "content-encoding" => "gzip" }, [ "compressed" ] ], [ 200, { "content-length" => "102401" }, [] ],
      [ 200, {}, [ "a" * 102_400, "b" ] ] ].each do |code, headers, chunks|
      assert_raises(HttpTarget::Error) { perform_response(code:, headers:, chunks:) }
    end
    assert_equal "a" * 102_400, perform_response(code: 200, chunks: [ "a" * 51_200, "a" * 51_200 ])
    assert_raises(SupportOutput::Invalid) { perform_response(code: 200, chunks: [ "\xff".b ]) }
  end

  test "input bound malformed schemas and total deadline do not retry and never include private transport errors" do
    with_endpoint_approval(workspace_id: 17) do
      with_test_method(Resolv, :getaddresses, ->(*) { flunk "Oversize must fail before resolving" }) do
        assert_raises(HttpTarget::Error) { call_target({ "situation" => "a" * 1.megabyte }) }
      end
      with_test_method(Resolv, :getaddresses, ->(*) { [ "93.184.216.34" ] }) do
        [ "{unfinished", "{}" ].each do |body|
          with_test_method(HttpTarget, :perform, ->(*) { body }) { assert_raises(SupportOutput::Invalid) { call_target({}) } }
        end
        calls = 0
        with_test_method(HttpTarget, :perform, ->(*) { calls += 1; raise OpenSSL::SSL::SSLError, "test-only-token in unsafe error" }) do
          error = assert_raises(HttpTarget::Error) { call_target({}) }
          assert_not_includes error.message, "test-only-token"
          assert_equal 1, calls
        end
      end
      original_timeout = Timeout.method(:timeout)
      with_test_method(Timeout, :timeout, ->(seconds, &block) { assert_equal 30, seconds; original_timeout.call(0.02, &block) }) do
        with_test_method(Resolv, :getaddresses, ->(*) { sleep 0.1; flunk "Total deadline includes DNS" }) do
          assert_raises(HttpTarget::Error) { call_target({}) }
        end
      end
    end
  end

  private
    def call_target(input)
      HttpTarget.call(configuration: { "endpoint" => HTTP_ENDPOINT }, input:, workspace_id: 17, request_key: "test-request-key")
    end

    def perform_response(code:, headers: {}, chunks:)
      response = Net::HTTPResponse::CODE_TO_OBJ.fetch(code.to_s).new("1.1", code.to_s, "test")
      response["content-type"] = "application/json"
      headers.each { |key, value| response[key] = value }
      response.define_singleton_method(:read_body) { |&block| chunks.each(&block) }
      fake = Object.new
      fake.define_singleton_method(:request) { |_request, &block| block.call(response) }
      with_test_method(HttpTarget, :connection, ->(*) { fake }) do
        uri = URI(HTTP_ENDPOINT)
        HttpTarget.perform(uri, Net::HTTP::Post.new(uri.request_uri), "93.184.216.34")
      end
    end
end
