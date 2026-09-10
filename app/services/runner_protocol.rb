require "openssl"
require "uri"

module RunnerProtocol
  VERSION = "v1"
  ADMISSION_VERSION = "v2"
  ADMISSION_PATH = "/v2/runs/admit"
  RUNTIME_DETECTION_VERSION = "v2"
  RUNTIME_DETECTION_PATH = "/v2/runtimes/detect"
  RUNTIME_TEST_PATH = "/v1/runtimes/test"
  WEB_SEARCH_CATALOG_PATH = "/v1/tools/web-search/catalog"
  WEB_SEARCH_PATH = "/v1/tools/web-search"
  MAX_BODY_BYTES = 256.kilobytes
  BIGINT_MAX = 9_223_372_036_854_775_807
  UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i
  KEY_PATTERN = /\A[a-zA-Z0-9][a-zA-Z0-9._:-]{0,127}\z/
  POLICY_KEY_PATTERN = /\A[a-z][a-z0-9_]{0,63}\z/

  class Error < StandardError; end
  class MalformedMessage < Error; end

  module_function

  def signature(secret:, timestamp:, method:, path:, body:)
    digest = Digest::SHA256.hexdigest(body)
    payload = [ timestamp.to_s, method.to_s.upcase, path, digest ].join("\n")
    OpenSSL::HMAC.hexdigest("SHA256", secret, payload)
  end

  class AdmissionRequest
    KEYS = %w[protocol_version run_id idempotency_key workspace_key task agent routing].freeze
    TASK_KEYS = %w[task_key attempt title input_context expected_output].freeze
    AGENT_KEYS = %w[role_key policy_version instructions allowed_tools runtime_profile_key fallback_profile_keys timeout_seconds max_steps max_tool_calls review_policy].freeze
    ROUTING_KEYS = %w[
      detection_key configuration_fingerprint effective_model adapter_key profile_key selection_reason selection_detail
      execution_mode isolation_policy data_classes max_input_units max_output_units
    ].freeze

    attr_reader :attributes

    def self.protocol_version
      ADMISSION_VERSION
    end

    def self.for_task(task:, run:, run_id:, idempotency_key:, attempt:, input_context: task.input_context)
      version = task.assigned_agent_profile_version
      new(
        "protocol_version" => protocol_version,
        "run_id" => run_id,
        "idempotency_key" => idempotency_key,
        "workspace_key" => task.workspace.runner_key,
        "task" => {
          "task_key" => task.task_key,
          "attempt" => attempt,
          "title" => task.title,
          "input_context" => input_context,
          "expected_output" => task.expected_output
        },
        "agent" => {
          "role_key" => task.assigned_agent_profile.role_key,
          "policy_version" => version.version_number,
          "instructions" => version.instructions,
          "allowed_tools" => version.allowed_tools.sort,
          "runtime_profile_key" => version.runtime_profile_key,
          "fallback_profile_keys" => version.fallback_profile_keys,
          "timeout_seconds" => version.timeout_seconds,
          "max_steps" => version.max_steps,
          "max_tool_calls" => version.max_tool_calls,
          "review_policy" => version.review_policy
        },
        "routing" => routing_for(run)
      )
    end

    def self.routing_for(run)
      routing = {
        "detection_key" => run.selected_runtime_detection_key,
        "configuration_fingerprint" => run.selected_runtime_configuration_fingerprint,
        "effective_model" => run.selected_effective_model,
        "adapter_key" => run.selected_adapter_key,
        "profile_key" => run.selected_runtime_profile_key,
        "selection_reason" => run.runtime_selection_reason,
        "selection_detail" => run.runtime_selection_detail,
        "execution_mode" => run.selected_execution_mode,
        "isolation_policy" => run.selected_isolation_policy,
        "data_classes" => run.disclosed_data_classes,
        "max_input_units" => run.max_input_units,
        "max_output_units" => run.max_output_units
      }
      routing
    end

    def self.parse(body)
      raise MalformedMessage, "request body is too large" if body.bytesize > MAX_BODY_BYTES

      new(JSON.parse(body))
    rescue JSON::ParserError
      raise MalformedMessage, "request body is not valid JSON"
    end

    def initialize(attributes)
      validate!(attributes)
      @attributes = attributes.deep_dup.freeze
    end

    def run_id
      attributes.fetch("run_id")
    end

    def to_json(*)
      JSON.generate(attributes)
    end

    private

    def validate!(value)
      object!(value, KEYS, "request")
      equal!(value["protocol_version"], self.class.protocol_version, "protocol_version")
      uuid!(value["run_id"], "run_id")
      key!(value["idempotency_key"], "idempotency_key")
      uuid!(value["workspace_key"], "workspace_key")

      task = value["task"]
      object!(task, TASK_KEYS, "task")
      uuid!(task["task_key"], "task.task_key")
      integer!(task["attempt"], 1, 100, "task.attempt")
      string!(task["title"], 200, "task.title")
      string!(task["input_context"], 128.kilobytes, "task.input_context")
      string!(task["expected_output"], 8_000, "task.expected_output")

      agent = value["agent"]
      object!(agent, AGENT_KEYS, "agent")
      policy_key!(agent["role_key"], "agent.role_key")
      integer!(agent["policy_version"], 1, nil, "agent.policy_version")
      string!(agent["instructions"], 8_000, "agent.instructions")
      values!(agent["allowed_tools"], 8, "agent.allowed_tools")
      policy_key!(agent["runtime_profile_key"], "agent.runtime_profile_key")
      values!(agent["fallback_profile_keys"], 2, "agent.fallback_profile_keys")
      raise MalformedMessage, "agent fallback repeats primary runtime" if agent["fallback_profile_keys"].include?(agent["runtime_profile_key"])
      integer!(agent["timeout_seconds"], 30, 900, "agent.timeout_seconds")
      integer!(agent["max_steps"], 1, 20, "agent.max_steps")
      integer!(agent["max_tool_calls"], 0, 50, "agent.max_tool_calls")
      unless %w[required on_policy_flag].include?(agent["review_policy"])
        raise MalformedMessage, "agent.review_policy is invalid"
      end

      routing = value["routing"]
      object!(routing, self.class::ROUTING_KEYS, "routing")
      unless routing["detection_key"].is_a?(String) && routing["detection_key"].match?(/\A[0-9a-f]{64}\z/)
        raise MalformedMessage, "routing.detection_key is invalid"
      end
      unless routing["configuration_fingerprint"].is_a?(String) && routing["configuration_fingerprint"].match?(/\A[0-9a-f]{64}\z/)
        raise MalformedMessage, "routing.configuration_fingerprint is invalid"
      end
      string!(routing["effective_model"], 200, "routing.effective_model")
      if routing["effective_model"].match?(/[\r\n]/)
        raise MalformedMessage, "routing.effective_model is invalid"
      end
      policy_key!(routing["adapter_key"], "routing.adapter_key")
      policy_key!(routing["profile_key"], "routing.profile_key")
      unless RuntimeInstallation::KNOWN_EXECUTION_MODES.include?(routing["execution_mode"]) &&
          AgentPolicy::ISOLATION_POLICIES.key?(routing["isolation_policy"]) &&
          AgentPolicy.execution_mode_allowed?(routing["isolation_policy"], routing["execution_mode"])
        raise MalformedMessage, "routing execution boundary is invalid"
      end
      unless %w[primary fallback].include?(routing["selection_reason"])
        raise MalformedMessage, "routing.selection_reason is invalid"
      end
      string!(routing["selection_detail"], 500, "routing.selection_detail")
      values!(routing["data_classes"], 8, "routing.data_classes")
      integer!(routing["max_input_units"], 1, 10_000_000, "routing.max_input_units")
      integer!(routing["max_output_units"], 1, 10_000_000, "routing.max_output_units")
    end

    def object!(value, keys, name)
      raise MalformedMessage, "#{name} must be an object" unless value.is_a?(Hash)
      raise MalformedMessage, "#{name} has unexpected fields" unless value.keys.sort == keys.sort
    end

    def equal!(value, expected, name)
      raise MalformedMessage, "#{name} is unsupported" unless value == expected
    end

    def uuid!(value, name)
      raise MalformedMessage, "#{name} is invalid" unless value.is_a?(String) && value.match?(UUID_PATTERN)
    end

    def key!(value, name)
      raise MalformedMessage, "#{name} is invalid" unless value.is_a?(String) && value.match?(KEY_PATTERN)
    end

    def policy_key!(value, name)
      raise MalformedMessage, "#{name} is invalid" unless value.is_a?(String) && value.match?(POLICY_KEY_PATTERN)
    end

    def string!(value, maximum, name)
      raise MalformedMessage, "#{name} is invalid" unless value.is_a?(String) && value.present? && value.bytesize <= maximum
    end

    def integer!(value, minimum, maximum, name)
      valid = value.is_a?(Integer) && value >= minimum && (maximum.nil? || value <= maximum)
      raise MalformedMessage, "#{name} is invalid" unless valid
    end

    def values!(value, maximum, name)
      unless value.is_a?(Array) && value.length <= maximum && value.uniq.length == value.length && value.all? { |item| item.is_a?(String) && item.match?(POLICY_KEY_PATTERN) }
        raise MalformedMessage, "#{name} is invalid"
      end
    end
  end

  class AdmissionResponse
    KEYS = %w[protocol_version run_id status event].freeze
    EVENT_KEYS = %w[protocol_version event_id run_id sequence event_type occurred_at data].freeze
    EVENT_DATA_KEYS = %w[workspace_key task_key attempt].freeze

    attr_reader :attributes

    def self.protocol_version
      ADMISSION_VERSION
    end

    def self.parse(body, expected_run_id:, expected_data: nil)
      raise MalformedMessage, "response body is too large" if body.bytesize > MAX_BODY_BYTES

      new(JSON.parse(body), expected_run_id: expected_run_id, expected_data: expected_data)
    rescue JSON::ParserError
      raise MalformedMessage, "response body is not valid JSON"
    end

    def initialize(attributes, expected_run_id:, expected_data: nil)
      object!(attributes, KEYS, "response")
      equal!(attributes["protocol_version"], self.class.protocol_version, "protocol_version")
      equal!(attributes["run_id"], expected_run_id, "run_id")
      equal!(attributes["status"], "accepted", "status")

      event = attributes["event"]
      object!(event, EVENT_KEYS, "event")
      equal!(event["protocol_version"], VERSION, "event.protocol_version")
      uuid!(event["event_id"], "event.event_id")
      equal!(event["run_id"], expected_run_id, "event.run_id")
      equal!(event["sequence"], 1, "event.sequence")
      equal!(event["event_type"], "run.admitted", "event.event_type")
      time!(event["occurred_at"], "event.occurred_at")
      object!(event["data"], EVENT_DATA_KEYS, "event.data")
      uuid!(event.dig("data", "workspace_key"), "event.data.workspace_key")
      uuid!(event.dig("data", "task_key"), "event.data.task_key")
      unless event.dig("data", "attempt").is_a?(Integer) && event.dig("data", "attempt").between?(1, 100)
        raise MalformedMessage, "event.data.attempt is invalid"
      end
      equal!(event["data"], expected_data, "event.data") if expected_data
      @attributes = attributes.deep_dup.freeze
    end

    def event
      attributes.fetch("event")
    end

    private

    def object!(value, keys, name)
      raise MalformedMessage, "#{name} must be an object" unless value.is_a?(Hash)
      raise MalformedMessage, "#{name} has unexpected fields" unless value.keys.sort == keys.sort
    end

    def equal!(value, expected, name)
      raise MalformedMessage, "#{name} does not match" unless value == expected
    end

    def uuid!(value, name)
      raise MalformedMessage, "#{name} is invalid" unless value.is_a?(String) && value.match?(UUID_PATTERN)
    end

    def time!(value, name)
      raise MalformedMessage, "#{name} is invalid" unless value.is_a?(String)

      Time.iso8601(value)
    rescue ArgumentError
      raise MalformedMessage, "#{name} is invalid"
    end
  end

  class WebSearchCatalogResponse
    attr_reader :attributes

    def self.parse(body, workspace_key:)
      raise MalformedMessage, "response body is too large" if body.bytesize > MAX_BODY_BYTES

      new(JSON.parse(body), workspace_key:)
    rescue JSON::ParserError
      raise MalformedMessage, "response body is not valid JSON"
    end

    def initialize(attributes, workspace_key:)
      keys = attributes.is_a?(Hash) && attributes["provider_keys"]
      unless attributes.is_a?(Hash) && attributes.keys.sort == %w[default_provider_key protocol_version provider_keys workspace_key] &&
          attributes["protocol_version"] == VERSION && attributes["workspace_key"] == workspace_key &&
          keys.is_a?(Array) && keys.length <= 100 && keys.uniq == keys &&
          keys.all? { |key| key.is_a?(String) && key.match?(POLICY_KEY_PATTERN) } &&
          (attributes["default_provider_key"] == "" || keys.include?(attributes["default_provider_key"]))
        raise MalformedMessage, "web search catalog is invalid"
      end
      @attributes = attributes.deep_dup.freeze
    end
  end

  class WebSearchResponse
    KEYS = %w[protocol_version workspace_key request_key query provider_key policy_decision cost_units retrieved_at results].freeze
    RESULT_KEYS = %w[rank title url excerpt published_at].freeze

    attr_reader :attributes

    def self.parse(body, workspace_key:, request_key:, query:, provider_key: nil)
      raise MalformedMessage, "response body is too large" if body.bytesize > MAX_BODY_BYTES

      new(JSON.parse(body), workspace_key:, request_key:, query:, provider_key:)
    rescue JSON::ParserError
      raise MalformedMessage, "response body is not valid JSON"
    end

    def initialize(attributes, workspace_key:, request_key:, query:, provider_key: nil)
      unless attributes.is_a?(Hash) && attributes.keys.sort == KEYS.sort &&
          attributes["protocol_version"] == VERSION && attributes["workspace_key"] == workspace_key &&
          attributes["request_key"] == request_key && attributes["query"] == query &&
          (provider_key.nil? || attributes["provider_key"] == provider_key) && attributes["provider_key"].is_a?(String) && attributes["provider_key"].match?(POLICY_KEY_PATTERN) &&
          attributes["policy_decision"] == "allowed" && attributes["cost_units"].is_a?(Integer) &&
          attributes["cost_units"].between?(0, BIGINT_MAX) &&
          valid_time?(attributes["retrieved_at"]) && valid_results?(attributes["results"])
        raise MalformedMessage, "web search response is invalid"
      end
      @attributes = attributes.deep_dup.freeze
    end

    private
      def valid_results?(results)
        return false unless results.is_a?(Array) && results.length <= 10

        results.each_with_index.all? do |result, index|
          result.is_a?(Hash) && result.keys.sort == RESULT_KEYS.sort && result["rank"] == index + 1 &&
            result["title"].is_a?(String) && result["title"].bytesize.between?(1, 500) &&
            valid_url?(result["url"]) && result["excerpt"].is_a?(String) && result["excerpt"].bytesize <= 4_000 &&
            (result["published_at"].nil? || valid_time?(result["published_at"]))
        end
      end

      def valid_url?(value)
        uri = URI.parse(value.to_s)
        uri.scheme == "https" && uri.host.present? && uri.userinfo.nil? && uri.fragment.nil? && value.bytesize <= 2_048
      rescue URI::InvalidURIError
        false
      end

      def valid_time?(value)
        Time.iso8601(value.to_s)
        true
      rescue ArgumentError
        false
      end
  end

  class RuntimeDetectionResponse
    KEYS = %w[protocol_version installations].freeze
    INSTALLATION_KEYS = %w[
      detection_key adapter_key protocol_version executable_path executable_version account_metadata
      capabilities transport execution_mode effective_model configuration_fingerprint minimum_version maximum_version compatibility_status
      incompatibility_reason health_status checked_at
    ].freeze

    attr_reader :installations

    def self.parse(body)
      raise MalformedMessage, "response body is too large" if body.bytesize > MAX_BODY_BYTES

      new(JSON.parse(body))
    rescue JSON::ParserError
      raise MalformedMessage, "response body is not valid JSON"
    end

    def initialize(attributes)
      object!(attributes, KEYS, "response")
      equal!(attributes["protocol_version"], RUNTIME_DETECTION_VERSION, "protocol_version")
      values = attributes["installations"]
      raise MalformedMessage, "installations is invalid" unless values.is_a?(Array) && values.size <= 32

      values.each_with_index { |installation, index| validate_installation!(installation, index) }
      keys = values.map { |installation| installation["detection_key"] }
      raise MalformedMessage, "installations contains duplicates" unless keys.uniq.size == keys.size

      @installations = values.deep_dup.freeze
    end

    private
      def validate_installation!(installation, index)
        name = "installations[#{index}]"
        object!(installation, INSTALLATION_KEYS, name)
        string!(installation["detection_key"], 64, "#{name}.detection_key", /\A[0-9a-f]{64}\z/)
        string!(installation["adapter_key"], 64, "#{name}.adapter_key", POLICY_KEY_PATTERN)
        string!(installation["protocol_version"], 16, "#{name}.protocol_version", /\Av[1-9][0-9]*\z/)
        string!(installation["executable_path"], 4_096, "#{name}.executable_path", /\A\//)
        string!(installation["executable_version"], 8.kilobytes, "#{name}.executable_version")
        metadata = installation["account_metadata"]
        sensitive_key = /passw|secret|token|credential|cookie|authorization|private|session/i
        unless metadata.is_a?(Hash) && metadata.size <= 16 && metadata.all? { |key, value| key.is_a?(String) && key.match?(POLICY_KEY_PATTERN) && !key.match?(sensitive_key) && value.is_a?(String) && value.bytesize <= 500 }
          raise MalformedMessage, "#{name}.account_metadata is invalid"
        end
        values!(installation["capabilities"], 32, "#{name}.capabilities")
        unless RuntimeInstallation::KNOWN_TRANSPORTS.include?(installation["transport"])
          raise MalformedMessage, "#{name}.transport is invalid"
        end
        unless RuntimeInstallation::KNOWN_EXECUTION_MODES.include?(installation["execution_mode"])
          raise MalformedMessage, "#{name}.execution_mode is invalid"
        end
        string!(installation["effective_model"], 200, "#{name}.effective_model", /\A[^\r\n\x00]+\z/)
        string!(installation["configuration_fingerprint"], 64, "#{name}.configuration_fingerprint", /\A[0-9a-f]{64}\z/)
        string!(installation["minimum_version"], 100, "#{name}.minimum_version", nil, allow_empty: true)
        string!(installation["maximum_version"], 100, "#{name}.maximum_version", nil, allow_empty: true)
        unless RuntimeInstallation::COMPATIBILITY_STATUSES.include?(installation["compatibility_status"])
          raise MalformedMessage, "#{name}.compatibility_status is invalid"
        end
        string!(installation["incompatibility_reason"], 1_000, "#{name}.incompatibility_reason", nil, allow_empty: true)
        unless RuntimeInstallation::HEALTH_STATUSES.first(2).include?(installation["health_status"])
          raise MalformedMessage, "#{name}.health_status is invalid"
        end
        Time.iso8601(installation["checked_at"])
      rescue ArgumentError, TypeError
        raise MalformedMessage, "#{name}.checked_at is invalid"
      end

      def object!(value, keys, name)
        raise MalformedMessage, "#{name} must be an object" unless value.is_a?(Hash)
        raise MalformedMessage, "#{name} has unexpected fields" unless value.keys.sort == keys.sort
      end

      def equal!(value, expected, name)
        raise MalformedMessage, "#{name} does not match" unless value == expected
      end

      def string!(value, maximum, name, pattern = nil, allow_empty: false)
        valid = value.is_a?(String) && value.bytesize <= maximum && (allow_empty || value.present?)
        valid &&= value.match?(pattern) if pattern
        raise MalformedMessage, "#{name} is invalid" unless valid
      end

      def values!(value, maximum, name)
        valid = value.is_a?(Array) && value.size <= maximum && value == value.uniq.sort &&
          value.all? { |item| item.is_a?(String) && item.match?(POLICY_KEY_PATTERN) }
        raise MalformedMessage, "#{name} is invalid" unless valid
      end
  end

  class RuntimeTestResponse
    KEYS = %w[
      protocol_version workspace_key request_id detection_key execution_mode configuration_fingerprint effective_model
      status failure_code usage_observed input_units output_units tested_at
    ].freeze

    attr_reader :attributes

    def self.parse(body, workspace_key:, request_id:, detection_key:, execution_mode:, configuration_fingerprint:)
      raise MalformedMessage, "response body is too large" if body.bytesize > MAX_BODY_BYTES

      new(JSON.parse(body), workspace_key:, request_id:, detection_key:, execution_mode:, configuration_fingerprint:)
    rescue JSON::ParserError
      raise MalformedMessage, "response body is not valid JSON"
    end

    def initialize(attributes, workspace_key:, request_id:, detection_key:, execution_mode:, configuration_fingerprint:)
      valid = attributes.is_a?(Hash) && attributes.keys.sort == KEYS.sort &&
        attributes["protocol_version"] == VERSION && attributes["workspace_key"] == workspace_key &&
        attributes["request_id"] == request_id && attributes["detection_key"] == detection_key &&
        attributes["execution_mode"] == execution_mode && RuntimeInstallation::KNOWN_EXECUTION_MODES.include?(attributes["execution_mode"]) &&
        attributes["configuration_fingerprint"] == configuration_fingerprint &&
        configuration_fingerprint.match?(/\A[0-9a-f]{64}\z/) &&
        attributes["effective_model"].is_a?(String) && attributes["effective_model"].bytesize.between?(1, 200) &&
        !attributes["effective_model"].match?(/[\r\n\x00]/) && %w[passed failed].include?(attributes["status"]) &&
        [ true, false ].include?(attributes["usage_observed"]) && valid_units?(attributes["input_units"]) &&
        valid_units?(attributes["output_units"]) && valid_time?(attributes["tested_at"])
      valid &&= attributes["status"] == "passed" ? attributes["failure_code"].nil? : valid_failure_code?(attributes["failure_code"])
      raise MalformedMessage, "runtime test response is invalid" unless valid

      @attributes = attributes.deep_dup.freeze
    end

    private
      def valid_units?(value)
        value.is_a?(Integer) && value.between?(0, BIGINT_MAX)
      end

      def valid_time?(value)
        Time.iso8601(value.to_s)
        true
      rescue ArgumentError
        false
      end

      def valid_failure_code?(value)
        value.is_a?(String) && value.match?(/\A[a-z][a-z0-9_]{0,63}\z/)
      end
  end

  class CanonicalEvent
    KEYS = %w[protocol_version event_id run_id sequence event_type occurred_at data].freeze
    DATA_KEYS = {
      "run.admitted" => %w[workspace_key task_key attempt],
      "run.started" => %w[adapter scenario attempt],
      "tool.completed" => %w[tool result],
      "output.produced" => %w[text],
      "usage.observed" => %w[input_units output_units],
      "run.completed" => %w[outcome],
      "run.failed" => %w[code retryable],
      "run.timed_out" => %w[reason],
      "run.canceled" => %w[reason],
      "run.policy_denied" => %w[code tool]
    }.freeze

    attr_reader :attributes, :occurred_at

    def self.parse(body)
      raise MalformedMessage, "event body is too large" if body.bytesize > MAX_BODY_BYTES

      new(JSON.parse(body))
    rescue JSON::ParserError
      raise MalformedMessage, "event body is not valid JSON"
    end

    def initialize(attributes)
      object!(attributes, KEYS, "event")
      equal!(attributes["protocol_version"], VERSION, "event.protocol_version")
      uuid!(attributes["event_id"], "event.event_id")
      uuid!(attributes["run_id"], "event.run_id")
      integer!(attributes["sequence"], 1, "event.sequence")
      event_type = attributes["event_type"]
      data_keys = DATA_KEYS[event_type] || raise(MalformedMessage, "event.event_type is invalid")
      @occurred_at = parse_time(attributes["occurred_at"])
      data = attributes["data"]
      if event_type == "usage.observed"
        valid_keys = [ data_keys.sort, (data_keys + %w[amount_micros currency]).sort ]
        unless data.is_a?(Hash) && valid_keys.include?(data.keys.sort)
          raise MalformedMessage, "event.data has unexpected fields"
        end
      else
        object!(data, data_keys, "event.data")
      end
      validate_data!(event_type, data)
      raise MalformedMessage, "event.data is too large" if JSON.generate(data).bytesize > 128.kilobytes

      @attributes = attributes.deep_dup.freeze
    end

    private
      def validate_data!(event_type, data)
        case event_type
        when "run.admitted"
          uuid!(data["workspace_key"], "event.data.workspace_key")
          uuid!(data["task_key"], "event.data.task_key")
          integer!(data["attempt"], 1, "event.data.attempt")
        when "run.started"
          string!(data["adapter"], 64, "event.data.adapter")
          string!(data["scenario"], 100, "event.data.scenario")
          integer!(data["attempt"], 1, "event.data.attempt")
        when "tool.completed"
          string!(data["tool"], 64, "event.data.tool")
          string!(data["result"], 100, "event.data.result")
        when "output.produced"
          string!(data["text"], 100.kilobytes, "event.data.text")
        when "usage.observed"
          integer!(data["input_units"], 0, "event.data.input_units")
          integer!(data["output_units"], 0, "event.data.output_units")
          if data.key?("amount_micros")
            integer!(data["amount_micros"], 0, "event.data.amount_micros", maximum: BIGINT_MAX)
            unless data["currency"].is_a?(String) && data["currency"].match?(/\A[A-Z]{3}\z/)
              raise MalformedMessage, "event.data.currency is invalid"
            end
          end
        when "run.completed"
          equal!(data["outcome"], "completed", "event.data.outcome")
        when "run.failed"
          string!(data["code"], 100, "event.data.code")
          boolean!(data["retryable"], "event.data.retryable")
        when "run.timed_out", "run.canceled"
          string!(data["reason"], 500, "event.data.reason")
        when "run.policy_denied"
          string!(data["code"], 100, "event.data.code")
          string!(data["tool"], 64, "event.data.tool")
        end
      end

      def object!(value, keys, name)
        raise MalformedMessage, "#{name} must be an object" unless value.is_a?(Hash)
        raise MalformedMessage, "#{name} has unexpected fields" unless value.keys.sort == keys.sort
      end

      def equal!(value, expected, name)
        raise MalformedMessage, "#{name} does not match" unless value == expected
      end

      def uuid!(value, name)
        raise MalformedMessage, "#{name} is invalid" unless value.is_a?(String) && value.match?(UUID_PATTERN)
      end

      def integer!(value, minimum, name, maximum: nil)
        valid = value.is_a?(Integer) && value >= minimum && (maximum.nil? || value <= maximum)
        raise MalformedMessage, "#{name} is invalid" unless valid
      end

      def string!(value, maximum, name)
        raise MalformedMessage, "#{name} is invalid" unless value.is_a?(String) && value.present? && value.bytesize <= maximum
      end

      def boolean!(value, name)
        raise MalformedMessage, "#{name} is invalid" unless value == true || value == false
      end

      def parse_time(value)
        raise MalformedMessage, "event.occurred_at is invalid" unless value.is_a?(String)

        Time.iso8601(value)
      rescue ArgumentError
        raise MalformedMessage, "event.occurred_at is invalid"
      end
  end
end
