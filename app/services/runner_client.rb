require "net/http"
require "ipaddr"

class RunnerClient
  class Error < StandardError; end
  class ConfigurationError < Error; end
  class Unavailable < Error; end
  class AmbiguousResult < Error; end
  class AuthenticationError < Error; end
  class PolicyDenied < Error; end
  class Conflict < Error; end
  class MalformedResponse < Error; end

  Response = Data.define(:code, :body)

  def initialize(address: ENV["NAVISHAI_RUNNER_ADDRESS"], secret: ENV["NAVISHAI_RUNNER_SHARED_SECRET"], clock: -> { Time.current })
    @base_uri = parse_address(address.presence || "http://127.0.0.1:8081")
    @secret = secret.to_s.b
    @clock = clock
    raise ConfigurationError, "runner shared secret must contain at least 32 bytes" if @secret.bytesize < 32
  end

  def admit!(task:, run:, run_id:, idempotency_key:, attempt:, input_context: task.input_context)
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
  rescue SocketError, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH => error
    raise Unavailable, "runner is unavailable: #{error.class}"
  end

  def ready?
    response = perform(Net::HTTP::Get.new("/readyz"))
    return false unless response.code == 200

    payload = JSON.parse(response.body)
    payload == { "status" => "ok", "protocol_versions" => [ RunnerProtocol::VERSION ] }
  rescue Error, JSON::ParserError, SystemCallError, Timeout::Error
    false
  end

  def detect_runtimes!(workspace_key:)
    body = JSON.generate(protocol_version: RunnerProtocol::VERSION, workspace_key: workspace_key)
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
  rescue SocketError, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH => error
    raise Unavailable, "runner is unavailable: #{error.class}"
  end

  def web_search!(workspace_key:, request_key:, query:, max_results: 5)
    body = JSON.generate(
      protocol_version: RunnerProtocol::VERSION, workspace_key:, request_key:, query:, max_results:
    )
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

    RunnerProtocol::WebSearchResponse.parse(response.body, workspace_key:, request_key:, query:).attributes
  rescue RunnerProtocol::MalformedMessage => error
    raise MalformedResponse, error.message
  rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, EOFError, Errno::ECONNRESET, Errno::EPIPE => error
    raise AmbiguousResult, "web search outcome is unknown: #{error.class}"
  rescue SocketError, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH => error
    raise Unavailable, "runner is unavailable: #{error.class}"
  end

  private

  def parse_address(address)
    uri = URI.parse(address)
    unless %w[http https].include?(uri.scheme) && uri.host.present? && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil? && [ "", "/" ].include?(uri.path)
      raise ConfigurationError, "runner address must be an HTTP origin"
    end
    if uri.scheme != "https" && !loopback?(uri.host)
      raise ConfigurationError, "runner address must use HTTPS outside loopback"
    end
    uri
  rescue URI::InvalidURIError
    raise ConfigurationError, "runner address is invalid"
  end

  def loopback?(host)
    host == "localhost" || IPAddr.new(host).loopback?
  rescue IPAddr::InvalidAddressError
    false
  end

  def perform(request)
    http = Net::HTTP.new(@base_uri.host, @base_uri.port, nil)
    http.use_ssl = @base_uri.scheme == "https"
    http.verify_mode = OpenSSL::SSL::VERIFY_PEER if http.use_ssl?
    http.open_timeout = 3
    http.read_timeout = 10
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
    return "runner rejected the request" unless payload.is_a?(Hash) && payload.keys.sort == %w[error protocol_version] && payload["protocol_version"] == RunnerProtocol::VERSION
    return "runner rejected the request" unless payload["error"].is_a?(Hash) && payload["error"].keys.sort == %w[code message]

    payload["error"]["message"].to_s.first(500).presence || "runner rejected the request"
  rescue JSON::ParserError
    "runner rejected the request"
  end
end
