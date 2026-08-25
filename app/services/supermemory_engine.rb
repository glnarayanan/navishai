require "net/http"
require "ipaddr"

class SupermemoryEngine < MemoryEngine::Adapter
  class Error < StandardError; end
  class ConfigurationError < Error; end
  class Unavailable < Error; end
  class AmbiguousResult < Error; end
  class AuthenticationError < Error; end
  class MalformedResponse < Error; end
  class TenantMismatch < MalformedResponse; end

  Response = Data.define(:code, :body)
  MAX_RESPONSE_BYTES = 1.megabyte
  DOCUMENT_STATUSES = %w[queued extracting chunking embedding done failed].freeze
  MANAGED_HOST_SUFFIX = "supermemory.ai"

  def self.default
    new(
      address: ENV["NAVISHAI_SUPERMEMORY_ADDRESS"],
      api_key: ENV["NAVISHAI_SUPERMEMORY_API_KEY"] || Rails.application.credentials.dig(:memory, :supermemory_api_key)
    )
  end

  def initialize(address: nil, api_key: nil)
    @base_uri = parse_address(address.presence || "http://127.0.0.1:6767")
    @api_key = api_key.to_s
    unless @api_key.start_with?("sm_") && @api_key.bytesize.between?(16, 500)
      raise ConfigurationError, "self-hosted Supermemory API key is invalid"
    end
  end

  def health
    response = perform(request(Net::HTTP::Get, "/v3/documents/processing"))
    raise_for_response(response) unless response.code.between?(200, 299)

    MemoryEngine::Health.new(available: true, detail: "ready")
  rescue Error, SystemCallError, Timeout::Error, JSON::ParserError => error
    MemoryEngine::Health.new(available: false, detail: error.class.name.demodulize)
  end

  def index(document:)
    validate_document!(document)
    body = JSON.generate(
      content: document.content,
      customId: document.memory_key,
      containerTag: document.workspace_key,
      metadata: document_metadata(document),
      taskType: "superrag"
    )
    response = perform(request(Net::HTTP::Post, "/v3/documents", body:))
    raise_for_response(response) unless response.code == 200 || response.code == 202

    payload = parse_object(response.body)
    document_id = bounded_string(payload["id"], "document id", 200)
    status = document_status(payload["status"])
    MemoryEngine::IndexReceipt.new(document_id:, status:)
  rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, EOFError, Errno::ECONNRESET, Errno::EPIPE => error
    raise AmbiguousResult, "Supermemory indexing outcome is unknown: #{error.class}"
  rescue SocketError, OpenSSL::SSL::SSLError, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH => error
    raise Unavailable, "self-hosted Supermemory is unavailable: #{error.class}"
  end

  def search(query:)
    body = JSON.generate(
      q: query.text,
      containerTag: query.workspace_key,
      searchMode: "documents",
      limit: query.limit,
      filters: search_filters(query)
    )
    response = perform(request(Net::HTTP::Post, "/v4/search", body:))
    raise_for_response(response) unless response.code == 200

    payload = parse_object(response.body)
    results = payload["results"]
    raise MalformedResponse, "Supermemory search results are invalid" unless results.is_a?(Array) && results.length <= query.limit

    results.map { |result| parse_hit(result, query) }
      .group_by(&:memory_key)
      .values
      .map { |hits| hits.max_by(&:score) }
      .sort_by { |hit| -hit.score }
  rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, OpenSSL::SSL::SSLError,
      SocketError, SystemCallError, EOFError => error
    raise Unavailable, "self-hosted Supermemory is unavailable: #{error.class}"
  end

  def status(organization_key:, workspace_key:, memory_key:)
    validate_tenant_keys!(organization_key:, workspace_key:)
    payload = fetch_document(memory_key)
    verify_tenant!(payload, organization_key:, workspace_key:, memory_key:)
    MemoryEngine::IndexStatus.new(
      status: document_status(payload["status"]),
      detail: payload["failureReason"].to_s.first(500).presence
    )
  rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, OpenSSL::SSL::SSLError,
      SocketError, SystemCallError, EOFError => error
    raise Unavailable, "self-hosted Supermemory is unavailable: #{error.class}"
  end

  def remove(organization_key:, workspace_key:, memory_key:)
    validate_tenant_keys!(organization_key:, workspace_key:)
    payload = fetch_document(memory_key, allow_missing: true)
    return false unless payload

    verify_tenant!(payload, organization_key:, workspace_key:, memory_key:)
    response = perform(request(Net::HTTP::Delete, document_path(memory_key)))
    raise_for_response(response) unless response.code.between?(200, 299)
    true
  rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, EOFError, Errno::ECONNRESET, Errno::EPIPE => error
    raise AmbiguousResult, "Supermemory deletion outcome is unknown: #{error.class}"
  rescue SocketError, OpenSSL::SSL::SSLError, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH => error
    raise Unavailable, "self-hosted Supermemory is unavailable: #{error.class}"
  end

  private
    def parse_address(address)
      uri = URI.parse(address)
      unless %w[http https].include?(uri.scheme) && uri.host.present? && uri.userinfo.nil? &&
          uri.query.nil? && uri.fragment.nil? && [ "", "/" ].include?(uri.path)
        raise ConfigurationError, "Supermemory address must be an HTTP origin"
      end
      host = uri.host.downcase.delete_suffix(".")
      if host == MANAGED_HOST_SUFFIX || host.end_with?(".#{MANAGED_HOST_SUFFIX}")
        raise ConfigurationError, "managed Supermemory is not supported"
      end
      if uri.scheme != "https" && !loopback?(uri.host)
        raise ConfigurationError, "Supermemory address must use HTTPS outside loopback"
      end
      uri
    rescue URI::InvalidURIError
      raise ConfigurationError, "Supermemory address is invalid"
    end

    def loopback?(host)
      host == "localhost" || IPAddr.new(host).loopback?
    rescue IPAddr::InvalidAddressError
      false
    end

    def request(request_class, path, body: nil)
      request = request_class.new(path)
      request["Authorization"] = "Bearer #{@api_key}"
      request["Accept"] = "application/json"
      if body
        request["Content-Type"] = "application/json"
        request.body = body
      end
      request
    end

    def perform(request)
      http = Net::HTTP.new(@base_uri.host, @base_uri.port, nil)
      http.use_ssl = @base_uri.scheme == "https"
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER if http.use_ssl?
      http.open_timeout = 3
      http.read_timeout = 15
      http.write_timeout = 10

      body = +"".b
      code = nil
      http.start do
        http.request(request) do |response|
          code = response.code.to_i
          if response.content_length && response.content_length > MAX_RESPONSE_BYTES
            raise MalformedResponse, "Supermemory response is too large"
          end
          response.read_body do |chunk|
            body << chunk.b
            raise MalformedResponse, "Supermemory response is too large" if body.bytesize > MAX_RESPONSE_BYTES
          end
        end
      end
      Response.new(code:, body:)
    end

    def document_metadata(document)
      {
        "navishai_organization_key" => document.organization_key,
        "navishai_workspace_key" => document.workspace_key,
        "navishai_memory_key" => document.memory_key,
        "memory_type" => document.memory_type,
        "scope_kind" => document.scope_kind,
        "scope_key" => document.scope_key
      }
    end

    def search_filters(query)
      {
        "AND" => [
          { "key" => "navishai_organization_key", "value" => query.organization_key },
          { "key" => "navishai_workspace_key", "value" => query.workspace_key },
          {
            "OR" => query.scope_filters.map do |scope|
              {
                "AND" => [
                  { "key" => "scope_kind", "value" => scope.kind },
                  { "key" => "scope_key", "value" => scope.key }
                ]
              }
            end
          }
        ]
      }
    end

    def parse_hit(result, query)
      raise MalformedResponse, "Supermemory search result is invalid" unless result.is_a?(Hash)

      metadata = result["metadata"]
      verify_tenant!(metadata, organization_key: query.organization_key, workspace_key: query.workspace_key)
      memory_key = bounded_string(metadata["navishai_memory_key"], "memory key", 100)
      raise MalformedResponse, "Supermemory memory key is invalid" unless memory_key.match?(MemoryEngine::UUID_PATTERN)
      score = result["similarity"]
      unless score.is_a?(Numeric) && score.between?(0, 1)
        raise MalformedResponse, "Supermemory search score is invalid"
      end
      unless query.scope_filters.any? { |scope| scope.kind == metadata["scope_kind"] && scope.key == metadata["scope_key"] }
        raise TenantMismatch, "Supermemory returned a memory outside the requested scope"
      end

      MemoryEngine::Hit.new(memory_key:, score: score.to_f)
    end

    def fetch_document(memory_key, allow_missing: false)
      response = perform(request(Net::HTTP::Get, document_path(memory_key)))
      return nil if allow_missing && response.code == 404

      raise_for_response(response) unless response.code == 200
      parse_object(response.body)
    end

    def verify_tenant!(payload, organization_key:, workspace_key:, memory_key: nil)
      metadata = payload.is_a?(Hash) && payload["metadata"].is_a?(Hash) ? payload["metadata"] : payload
      unless metadata.is_a?(Hash) && metadata["navishai_organization_key"] == organization_key &&
          metadata["navishai_workspace_key"] == workspace_key &&
          (!memory_key || metadata["navishai_memory_key"] == memory_key)
        raise TenantMismatch, "Supermemory returned a document from another tenant"
      end
    end

    def document_path(memory_key)
      key = bounded_string(memory_key, "memory key", 100)
      raise ConfigurationError, "memory key is invalid" unless key.match?(MemoryEngine::UUID_PATTERN)
      "/v3/documents/#{URI.encode_www_form_component(key)}"
    end

    def validate_document!(document)
      unless document.is_a?(MemoryEngine::Document) && document.organization_key.to_s.present? &&
          document.workspace_key.to_s.match?(MemoryEngine::UUID_PATTERN) &&
          document.memory_key.to_s.match?(MemoryEngine::UUID_PATTERN) &&
          document.memory_type.to_s.in?(MemoryRecord::MEMORY_TYPES) &&
          document.scope_kind.to_s.in?(MemoryRecord::SCOPE_KINDS) && document.scope_key.to_s.present?
        raise ConfigurationError, "memory document identity is invalid"
      end
    end

    def validate_tenant_keys!(organization_key:, workspace_key:)
      unless organization_key.to_s.present? && workspace_key.to_s.match?(MemoryEngine::UUID_PATTERN)
        raise ConfigurationError, "memory tenant identity is invalid"
      end
    end

    def parse_object(body)
      payload = JSON.parse(body)
      raise MalformedResponse, "Supermemory response is invalid" unless payload.is_a?(Hash)
      payload
    rescue JSON::ParserError
      raise MalformedResponse, "Supermemory response is invalid"
    end

    def bounded_string(value, name, maximum)
      string = value.to_s
      raise MalformedResponse, "Supermemory #{name} is invalid" unless string.present? && string.bytesize <= maximum
      string
    end

    def document_status(value)
      status = value.to_s
      raise MalformedResponse, "Supermemory document status is invalid" unless status.in?(DOCUMENT_STATUSES)
      status
    end

    def raise_for_response(response)
      case response.code
      when 401, 403 then raise AuthenticationError, "self-hosted Supermemory rejected authentication"
      when 400..499 then raise Error, "self-hosted Supermemory rejected the request with HTTP #{response.code}"
      else raise Unavailable, "self-hosted Supermemory returned HTTP #{response.code}"
      end
    end
end
