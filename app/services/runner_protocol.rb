require "openssl"

module RunnerProtocol
  VERSION = "v1"
  ADMISSION_PATH = "/v1/runs/admit"
  MAX_BODY_BYTES = 256.kilobytes
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
    KEYS = %w[protocol_version run_id idempotency_key workspace_key task agent].freeze
    TASK_KEYS = %w[task_key attempt title input_context expected_output].freeze
    AGENT_KEYS = %w[role_key policy_version instructions allowed_tools runtime_profile_key fallback_profile_keys timeout_seconds max_steps max_tool_calls review_policy].freeze

    attr_reader :attributes

    def self.for_task(task:, run_id:, idempotency_key:, attempt:)
      version = task.assigned_agent_profile_version
      new(
        "protocol_version" => VERSION,
        "run_id" => run_id,
        "idempotency_key" => idempotency_key,
        "workspace_key" => task.workspace.runner_key,
        "task" => {
          "task_key" => task.task_key,
          "attempt" => attempt,
          "title" => task.title,
          "input_context" => task.input_context,
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
        }
      )
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
      equal!(value["protocol_version"], VERSION, "protocol_version")
      uuid!(value["run_id"], "run_id")
      key!(value["idempotency_key"], "idempotency_key")
      uuid!(value["workspace_key"], "workspace_key")

      task = value["task"]
      object!(task, TASK_KEYS, "task")
      uuid!(task["task_key"], "task.task_key")
      integer!(task["attempt"], 1, 100, "task.attempt")
      string!(task["title"], 200, "task.title")
      string!(task["input_context"], 8_000, "task.input_context")
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

    def self.parse(body, expected_run_id:, expected_data: nil)
      raise MalformedMessage, "response body is too large" if body.bytesize > MAX_BODY_BYTES

      new(JSON.parse(body), expected_run_id: expected_run_id, expected_data: expected_data)
    rescue JSON::ParserError
      raise MalformedMessage, "response body is not valid JSON"
    end

    def initialize(attributes, expected_run_id:, expected_data: nil)
      object!(attributes, KEYS, "response")
      equal!(attributes["protocol_version"], VERSION, "protocol_version")
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
      object!(data, data_keys, "event.data")
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

      def integer!(value, minimum, name)
        raise MalformedMessage, "#{name} is invalid" unless value.is_a?(Integer) && value >= minimum
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
