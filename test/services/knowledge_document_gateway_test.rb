require "test_helper"

class KnowledgeDocumentGatewayTest < ActiveSupport::TestCase
  setup do
    @workspace_key = SecureRandom.uuid
    @data = "\xD0\xCF\x11\xE0\xA1\xB1\x1A\xE1document".b
    @gateway = KnowledgeDocumentGateway.new(secret: "s" * 32)
    @payload = { protocol_version: "v1", workspace_key: @workspace_key,
      content_sha256: Digest::SHA256.hexdigest(@data), format: "doc", converter: "libreoffice", text_base64: Base64.strict_encode64("Converted text") }
  end

  test "signs bounded bytes and uses isolated document transport limits" do
    captured = nil
    options = nil
    payload = @payload
    @gateway.define_singleton_method(:perform) do |request, **kwargs|
      captured = request
      options = kwargs
      RunnerClient::Response.new(code: 200, body: JSON.generate(payload))
    end
    assert_equal "Converted text", @gateway.extract_doc(data: @data, workspace_key: @workspace_key)
    assert_equal({ read_timeout: 45, max_response_bytes: 2.megabytes }, options)
    assert_equal @data, Base64.strict_decode64(JSON.parse(captured.body).fetch("content_base64"))
    assert_equal RunnerProtocol.signature(secret: "s" * 32, timestamp: captured["X-NavishAI-Timestamp"], method: "POST",
      path: KnowledgeDocumentGateway::PATH, body: captured.body), captured["X-NavishAI-Signature"]
    assert_equal %w[content_base64 content_sha256 format protocol_version workspace_key], JSON.parse(captured.body).keys.sort
  end

  test "rejects mismatched identity converter and malformed or oversized text" do
    [ { workspace_key: SecureRandom.uuid }, { content_sha256: "f" * 64 }, { converter: "other" },
      { text_base64: "%%%" }, { text_base64: Base64.strict_encode64("\xff".b) },
      { text_base64: Base64.strict_encode64("x" * (1.megabyte + 1)) } ].each do |changes|
      assert_raises(RunnerClient::MalformedResponse) do
        @gateway.send(:parse, JSON.generate(@payload.merge(changes)), workspace_key: @workspace_key, digest: Digest::SHA256.hexdigest(@data))
      end
    end
  end
end
