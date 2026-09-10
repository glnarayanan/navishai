require "base64"

class KnowledgeDocumentGateway < RunnerClient
  PATH = "/v1/documents/extract"
  MAX_RESPONSE_BYTES = 2.megabytes

  def extract_doc(data:, workspace_key:)
    unless workspace_key.is_a?(String) && workspace_key.match?(RunnerProtocol::UUID_PATTERN) &&
        data.bytesize.between?(1, StoredAttachment::MAX_BYTES)
      raise MalformedResponse, "invalid document conversion request"
    end
    digest = Digest::SHA256.hexdigest(data)
    body = JSON.generate(protocol_version: "v1", workspace_key:, content_sha256: digest,
      format: "doc", content_base64: Base64.strict_encode64(data))
    timestamp = @clock.call.to_i.to_s
    request = Net::HTTP::Post.new(PATH)
    request["Content-Type"] = "application/json"
    request["X-NavishAI-Timestamp"] = timestamp
    request["X-NavishAI-Signature"] = RunnerProtocol.signature(secret: @secret, timestamp:, method: "POST", path: PATH, body:)
    request.body = body
    response = perform(request, read_timeout: 45, max_response_bytes: MAX_RESPONSE_BYTES)
    raise_for_response(response) unless response.code == 200
    parse(response.body, workspace_key:, digest:)
  rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, EOFError, Errno::ECONNRESET, Errno::EPIPE,
      OpenSSL::SSL::SSLError, SocketError, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH
    raise Unavailable, "document converter is unavailable"
  end

  private
    def parse(body, workspace_key:, digest:)
      raise MalformedResponse, "document response is too large" if body.bytesize > MAX_RESPONSE_BYTES
      value = JSON.parse(body)
      unless value.is_a?(Hash) && value.keys.sort == %w[content_sha256 converter format protocol_version text_base64 workspace_key] &&
          value.values_at("protocol_version", "workspace_key", "content_sha256", "format", "converter") == [ "v1", workspace_key, digest, "doc", "libreoffice" ] &&
          value["text_base64"].is_a?(String)
        raise MalformedResponse, "document response identity is invalid"
      end
      text = Base64.strict_decode64(value.fetch("text_base64")).force_encoding(Encoding::UTF_8)
      unless text.valid_encoding? && text.bytesize.between?(1, KnowledgeSourceVersion::MAX_CONTENT_BYTES) && text.strip.present? && !text.include?("\x00")
        raise MalformedResponse, "document response text is invalid"
      end
      text
    rescue JSON::ParserError, ArgumentError
      raise MalformedResponse, "document response is invalid"
    end
end
