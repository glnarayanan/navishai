require "ipaddr"
require "net/http"
require "resolv"
require "timeout"

class EvaluationHttp
  DEADLINE = 30
  MAX_INPUT_BYTES = 1.megabyte
  MAX_RESPONSE_BYTES = 100.kilobytes
  BLOCKED_IPV4 = %w[0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.88.99.0/24 192.168.0.0/16 198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/3].map { |range| IPAddr.new(range) }.freeze
  BLOCKED_IPV6 = %w[2001::/23 2001:db8::/32 2002::/16 3fff::/20].map { |range| IPAddr.new(range) }.freeze
  GLOBAL_IPV6 = IPAddr.new("2000::/3")
  class Error < StandardError; end

  def self.endpoint(value)
    uri = URI.parse(value.to_s)
    valid = value.is_a?(String) && value.bytesize <= 2_048 && uri.is_a?(URI::HTTPS) && uri.hostname.present? &&
      uri.port == 443 && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil? && value == uri.to_s
    raise SupportOutput::Invalid, "Use an HTTPS endpoint on port 443 without URL credentials, query or fragment." unless valid
    uri
  rescue URI::InvalidURIError
    raise SupportOutput::Invalid, "The HTTP endpoint is invalid. Use an HTTPS URL."
  end

  def self.validate!(configuration, workspace_id:, purpose: :evaluation)
    unless configuration.is_a?(Hash) && configuration.keys == [ "endpoint" ]
      raise SupportOutput::Invalid, 'Use HTTP configuration JSON with only an "endpoint" HTTPS URL. Credentials belong in the operator environment, not this form.'
    end
    endpoint(configuration.fetch("endpoint"))
    approval!(configuration.fetch("endpoint"), workspace_id:, purpose:)
  end

  def self.approval!(url, workspace_id:, purpose: :evaluation)
    registry = { evaluation: "NAVISHAI_EVALUATION_ENDPOINTS", scenario: "NAVISHAI_SCENARIO_ENDPOINTS", corpus: "NAVISHAI_CORPUS_ENDPOINTS", matching: "NAVISHAI_MATCHING_ENDPOINTS" }.fetch(purpose)
    entries = JSON.parse(ENV.fetch(registry, "[]"))
    entry = entries.is_a?(Array) && entries.find { |candidate| candidate.is_a?(Hash) && candidate["workspace_id"] == workspace_id && candidate["endpoint"] == url }
    token = entry && entry["bearer_token"]
    unless entry && (token.nil? || (token.is_a?(String) && token.bytesize.between?(1, 8_192) && token.match?(/\A[\x21-\x7e]+\z/)))
      raise Error, "The operator has not approved this exact endpoint for this workspace, or its credential is invalid. No request was sent."
    end
    token
  rescue JSON::ParserError
    raise Error, "The operator endpoint registry is invalid. No request was sent."
  end

  def self.public_address?(address)
    ip = IPAddr.new(address)
    return !BLOCKED_IPV4.any? { |range| range.include?(ip) } if ip.ipv4?
    GLOBAL_IPV6.include?(ip) && !BLOCKED_IPV6.any? { |range| range.include?(ip) }
  rescue IPAddr::InvalidAddressError
    false
  end

  def self.call(configuration:, payload:, workspace_id:, request_key:, purpose: :evaluation)
    validate!(configuration, workspace_id:, purpose:)
    uri = endpoint(configuration.fetch("endpoint"))
    body = JSON.generate(payload)
    raise Error, "Target input exceeds 1 MiB. No request was sent." if body.bytesize > MAX_INPUT_BYTES
    request = Net::HTTP::Post.new(uri.request_uri)
    request["Content-Type"] = "application/json"
    request["Accept"] = "application/json"
    request["Accept-Encoding"] = "identity"
    request["Idempotency-Key"] = request_key
    token = approval!(uri.to_s, workspace_id:, purpose:)
    request["Authorization"] = "Bearer #{token}" if token
    request.body = body

    Timeout.timeout(DEADLINE) do
      addresses = Resolv.getaddresses(uri.hostname).uniq
      unless addresses.present? && addresses.size <= 16 && addresses.all? { |address| public_address?(address) }
        raise Error, "Endpoint DNS must resolve only to public addresses. No request was sent."
      end
      response = perform(uri, request, addresses.first)
      JSON.parse(response)
    end
  rescue JSON::ParserError, EncodingError
    raise SupportOutput::Invalid, "Target returned invalid JSON or text. This is an execution error."
  rescue SocketError, Resolv::ResolvError, SystemCallError, IOError, Timeout::Error, OpenSSL::SSL::SSLError, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError
    raise Error, "Target request failed or exceeded its deadline. Its remote outcome may be unknown; this request will not retry."
  end

  def self.connection(uri, address)
    http = Net::HTTP.new(uri.hostname, uri.port, nil)
    http.ipaddr = address
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_PEER
    http.verify_hostname = true
    http.min_version = OpenSSL::SSL::TLS1_2_VERSION
    http.open_timeout = 5
    http.read_timeout = 10
    http.write_timeout = 10
    http.max_retries = 0
    http
  end

  def self.perform(uri, request, address)
    body = +""
    connection(uri, address).request(request) do |response|
      raise Error, "Target did not return a successful JSON response. Redirects are not followed and the request will not retry." unless response.is_a?(Net::HTTPSuccess) && response.content_type == "application/json"
      raise Error, "Target returned compressed content. Only identity encoding is accepted." unless response["Content-Encoding"].to_s.in?([ "", "identity" ])
      raise Error, "Endpoint response exceeds 100 KiB." if response["Content-Length"].to_i > MAX_RESPONSE_BYTES
      response.read_body do |chunk|
        raise Error, "Endpoint response exceeds 100 KiB." if body.bytesize + chunk.bytesize > MAX_RESPONSE_BYTES
        body << chunk
      end
    end
    body.force_encoding(Encoding::UTF_8)
    raise SupportOutput::Invalid, "Target response must be valid UTF-8." unless body.valid_encoding?
    body
  end
end
