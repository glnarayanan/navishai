require "net/http"
require "ipaddr"
require "openssl"

class RunnerClient
  class Error < StandardError; end
  class ConfigurationError < Error; end
  class ClientConfigurationError < ConfigurationError; end
  class Unavailable < Error; end
  class AmbiguousResult < Error; end
  class AuthenticationError < Error; end
  class PolicyDenied < Error; end
  class Conflict < Error; end
  class MalformedResponse < Error; end

  Response = Data.define(:code, :body)

  def initialize(
    address: ENV["NAVISHAI_RUNNER_ADDRESS"],
    secret: ENV["NAVISHAI_RUNNER_SHARED_SECRET"],
    ca_file: ENV["NAVISHAI_RUNNER_CA_FILE"],
    clock: -> { Time.current }
  )
    @base_uri = parse_address(address.presence || "http://127.0.0.1:8081")
    @secret = secret.to_s.b
    @cert_store = build_cert_store(ca_file)
    @clock = clock
    raise ClientConfigurationError, "runner shared secret must contain at least 32 bytes" if @secret.bytesize < 32
  end

  def admit!(task:, run:, run_id:, idempotency_key:, attempt:, input_context: task.input_context)
    readiness_payload
    request_message = RunnerProtocol::AdmissionRequest.for_task(
      task: task, run: run,
      run_id: run_id,
      idempotency_key: idempotency_key,
      attempt: attempt,
      input_context: input_context
    )
    body = request_message.to_json
    timestamp = @clock.call.to_i.to_s
    request = Net::HTTP::Post.new(RunnerProtocol::ADMISSION_PATH)
    request["Content-Type"] = "application/json"
    request["X-NavishAI-Timestamp"] = timestamp
    request["X-NavishAI-Signature"] = RunnerProtocol.signature(
      secret: @secret,
      timestamp: timestamp,
      method: "POST",
      path: RunnerProtocol::ADMISSION_PATH,
      body: body
    )
    request.body = body

    response = perform(request)
    if response.code == 202
      expected_data = {
        "workspace_key" => request_message.attributes.fetch("workspace_key"),
        "task_key" => request_message.attributes.dig("task", "task_key"),
        "attempt" => request_message.attributes.dig("task", "attempt")
      }
      return parse_admission(response.body, run_id, expected_data:)
    end

    raise_for_response(response)
  rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, EOFError, Errno::ECONNRESET, Errno::EPIPE => error
    raise AmbiguousResult, "runner admission outcome is unknown: #{error.class}"
  rescue OpenSSL::SSL::SSLError, SocketError, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH => error
    raise Unavailable, "runner is unavailable: #{error.class}"
  end

  def ready?
    readiness_payload
    true
  rescue Unavailable
    false
  end

  def detect_runtimes!(workspace_key:)
    body = JSON.generate(protocol_version: RunnerProtocol::RUNTIME_DETECTION_VERSION, workspace_key: workspace_key)
    timestamp = @clock.call.to_i.to_s
    request = Net::HTTP::Post.new(RunnerProtocol::RUNTIME_DETECTION_PATH)
    request["Content-Type"] = "application/json"
    request["X-NavishAI-Timestamp"] = timestamp
    request["X-NavishAI-Signature"] = RunnerProtocol.signature(
      secret: @secret, timestamp: timestamp, method: "POST",
      path: RunnerProtocol::RUNTIME_DETECTION_PATH, body: body
    )
    request.body = body
    response = perform(request)
    raise_for_response(response) unless response.code == 200

    RunnerProtocol::RuntimeDetectionResponse.parse(response.body).installations
  rescue RunnerProtocol::MalformedMessage => error
    raise MalformedResponse, error.message
  rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, EOFError, Errno::ECONNRESET, Errno::EPIPE => error
    raise AmbiguousResult, "runner detection outcome is unknown: #{error.class}"
  rescue OpenSSL::SSL::SSLError, SocketError, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH => error
    raise Unavailable, "runner is unavailable: #{error.class}"
  end

  def test_runtime!(workspace_key:, request_id:, detection_key:, execution_mode:, configuration_fingerprint:)
    body = JSON.generate(
      protocol_version: RunnerProtocol::VERSION, workspace_key:, request_id:, detection_key:,
      execution_mode:, configuration_fingerprint:
    )
    timestamp = @clock.call.to_i.to_s
    request = Net::HTTP::Post.new(RunnerProtocol::RUNTIME_TEST_PATH)
    request["Content-Type"] = "application/json"
    request["X-NavishAI-Timestamp"] = timestamp
    request["X-NavishAI-Signature"] = RunnerProtocol.signature(
      secret: @secret, timestamp:, method: "POST", path: RunnerProtocol::RUNTIME_TEST_PATH, body:
    )
    request.body = body
    response = perform(request, read_timeout: 55)
    raise_for_response(response) unless response.code == 200

    RunnerProtocol::RuntimeTestResponse.parse(
      response.body, workspace_key:, request_id:, detection_key:, execution_mode:, configuration_fingerprint:
    ).attributes
  rescue RunnerProtocol::MalformedMessage => error
    raise MalformedResponse, error.message
  rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, EOFError, Errno::ECONNRESET, Errno::EPIPE => error
    raise AmbiguousResult, "runner test outcome is unknown: #{error.class}"
  rescue OpenSSL::SSL::SSLError, SocketError, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH => error
    raise Unavailable, "runner is unavailable: #{error.class}"
  end

  def web_search_catalog!(workspace_key:)
    body = JSON.generate(protocol_version: RunnerProtocol::VERSION, workspace_key:)
    timestamp = @clock.call.to_i.to_s
    path = RunnerProtocol::WEB_SEARCH_CATALOG_PATH
    request = Net::HTTP::Post.new(path)
    request["Content-Type"] = "application/json"
    request["X-NavishAI-Timestamp"] = timestamp
    request["X-NavishAI-Signature"] = RunnerProtocol.signature(secret: @secret, timestamp:, method: "POST", path:, body:)
    request.body = body
    response = perform(request)
    raise_for_response(response) unless response.code == 200
    RunnerProtocol::WebSearchCatalogResponse.parse(response.body, workspace_key:).attributes
  rescue RunnerProtocol::MalformedMessage => error
    raise MalformedResponse, error.message
  rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, EOFError, Errno::ECONNRESET, Errno::EPIPE,
      OpenSSL::SSL::SSLError, SocketError, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH => error
    raise Unavailable, "search catalog is unavailable: #{error.class}"
  end

  def web_search!(workspace_key:, request_key:, query:, max_results: 5, provider_key: nil)
    body = JSON.generate({ protocol_version: RunnerProtocol::VERSION, workspace_key:, request_key:, query:, max_results: }.tap do |payload|
      payload[:provider_key] = provider_key if provider_key.present?
    end)
    timestamp = @clock.call.to_i.to_s
    request = Net::HTTP::Post.new(RunnerProtocol::WEB_SEARCH_PATH)
    request["Content-Type"] = "application/json"
    request["X-NavishAI-Timestamp"] = timestamp
    request["X-NavishAI-Signature"] = RunnerProtocol.signature(
      secret: @secret, timestamp:, method: "POST", path: RunnerProtocol::WEB_SEARCH_PATH, body:
    )
    request.body = body
    response = perform(request)
    raise_for_response(response) unless response.code == 200

    RunnerProtocol::WebSearchResponse.parse(response.body, workspace_key:, request_key:, query:, provider_key:).attributes
  rescue RunnerProtocol::MalformedMessage => error
    raise MalformedResponse, error.message
  rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, EOFError, Errno::ECONNRESET, Errno::EPIPE => error
    raise AmbiguousResult, "web search outcome is unknown: #{error.class}"
  rescue OpenSSL::SSL::SSLError, SocketError, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH => error
    raise Unavailable, "runner is unavailable: #{error.class}"
  end

  private

  def parse_address(address)
    uri = URI.parse(address)
    unless %w[http https].include?(uri.scheme) && uri.host.present? && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil? && [ "", "/" ].include?(uri.path)
      raise ClientConfigurationError, "runner address must be an HTTP origin"
    end
    if uri.scheme != "https" && !loopback?(uri.host)
      raise ClientConfigurationError, "runner address must use HTTPS outside loopback"
    end
    uri
  rescue URI::InvalidURIError
    raise ClientConfigurationError, "runner address is invalid"
  end

  def loopback?(host)
    host == "localhost" || IPAddr.new(host).loopback?
  rescue IPAddr::InvalidAddressError
    false
  end

  def build_cert_store(ca_file)
    return if ca_file.blank?
    raise ClientConfigurationError, "runner CA file requires an HTTPS runner address" unless @base_uri.scheme == "https"

    store = OpenSSL::X509::Store.new
    store.set_default_paths
    store.add_file(ca_file)
    store
  rescue OpenSSL::X509::StoreError, SystemCallError => error
    raise ClientConfigurationError, "runner CA file could not be loaded: #{error.message}"
  end

  def perform(request, read_timeout: 10)
    http = Net::HTTP.new(@base_uri.host, @base_uri.port, nil)
    http.use_ssl = @base_uri.scheme == "https"
    if http.use_ssl?
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.cert_store = @cert_store if @cert_store
    end
    http.open_timeout = 3
    http.read_timeout = read_timeout
    http.write_timeout = 10

    body = +"".b
    code = nil
    http.start do
      http.request(request) do |response|
        code = response.code.to_i
        if response.content_length && response.content_length > RunnerProtocol::MAX_BODY_BYTES
          raise MalformedResponse, "runner response is too large"
        end
        response.read_body do |chunk|
          body << chunk.b
          raise MalformedResponse, "runner response is too large" if body.bytesize > RunnerProtocol::MAX_BODY_BYTES
        end
      end
    end
    Response.new(code:, body:)
  end

  def parse_admission(body, run_id, expected_data: nil)
    RunnerProtocol::AdmissionResponse.parse(body, expected_run_id: run_id, expected_data:)
  rescue RunnerProtocol::MalformedMessage => error
    raise MalformedResponse, error.message
  end

  def readiness_payload
    response = perform(Net::HTTP::Get.new("/readyz"))
    raise Unavailable, "runner readiness returned HTTP #{response.code}" unless response.code == 200

    payload = JSON.parse(response.body)
    unless payload.is_a?(Hash) && payload["status"] == "ok" &&
        payload["protocol_versions"] == [ RunnerProtocol::VERSION ] && valid_readiness_shape?(payload)
      raise Unavailable, "runner readiness response is invalid"
    end

    payload
  rescue JSON::ParserError, MalformedResponse, OpenSSL::SSL::SSLError, SocketError, SystemCallError, Timeout::Error, EOFError => error
    raise Unavailable, "runner readiness is unavailable: #{error.class}"
  end

  def valid_readiness_shape?(payload)
    payload.keys.sort == %w[admission_versions protocol_versions status] &&
      valid_admission_versions?(payload.fetch("admission_versions"))
  end

  def valid_admission_versions?(versions)
    return false unless versions.is_a?(Array) && versions.present? && versions.uniq.length == versions.length

    versions.all? { |version| version.is_a?(String) && version.in?([ RunnerProtocol::VERSION, RunnerProtocol::ADMISSION_VERSION ]) } &&
      versions.include?(RunnerProtocol::ADMISSION_VERSION)
  end

  def raise_for_response(response)
    message = error_message(response.body)
    case response.code
    when 401 then raise AuthenticationError, message
    when 403 then raise PolicyDenied, message
    when 409 then raise Conflict, message
    when 413, 415, 422 then raise ConfigurationError, message
    when 400..499 then raise Error, message
    else raise Unavailable, "runner returned HTTP #{response.code}"
    end
  end

  def error_message(body)
    payload = JSON.parse(body)
    supported_versions = [ RunnerProtocol::VERSION, RunnerProtocol::ADMISSION_VERSION, RunnerProtocol::RUNTIME_DETECTION_VERSION ]
    return "runner rejected the request" unless payload.is_a?(Hash) && payload.keys.sort == %w[error protocol_version] && payload["protocol_version"].in?(supported_versions)
    return "runner rejected the request" unless payload["error"].is_a?(Hash) && payload["error"].keys.sort == %w[code message]

    payload["error"]["message"].to_s.first(500).presence || "runner rejected the request"
  rescue JSON::ParserError
    "runner rejected the request"
  end
end
