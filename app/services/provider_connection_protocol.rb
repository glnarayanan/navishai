module ProviderConnectionProtocol
  VERSION = "v1"
  CATALOG_PATH = "/v1/providers/catalog"
  MODELS_PATH = "/v1/providers/models"
  CONFIGURE_PATH = "/v1/providers/configure"
  REMOVE_PATH = "/v1/providers/remove"
  PURGE_WORKSPACE_PATH = "/v1/providers/purge-workspace"
  PROVIDER_KEYS = %w[
    adapter_key name description auth_modes model_required configured secret_configured auth_mode model
    supported_execution_modes execution_mode health_status available unavailable_reason executable_version
  ].freeze
  EXECUTION_MODES = %w[bounded host_trusted strong_isolated legacy_unknown].freeze
  KEY_PATTERN = /\A[a-z][a-z0-9_]{0,63}\z/
  MODEL_RESPONSE_KEYS = %w[protocol_version workspace_key adapter_key execution_mode status checked_at models].freeze
  MODEL_OPTION_KEYS = %w[id label default].freeze
  MODEL_STATUSES = %w[available unsupported failed].freeze
  MAX_MODEL_OPTIONS = 100
  MAX_MODEL_ID_BYTES = 200
  MAX_MODEL_LABEL_BYTES = 200
  MAX_CHECKED_AT_BYTES = 64

  class MalformedMessage < StandardError; end

  module_function

  def parse_catalog(body, workspace_key:)
    attributes = parse_json(body)
    object!(attributes, %w[protocol_version workspace_key providers], "response")
    common_response!(attributes, workspace_key:)
    providers = attributes.fetch("providers")
    raise MalformedMessage, "providers must be an array" unless providers.is_a?(Array) && providers.size <= 32

    parsed = providers.map { |provider| provider!(provider) }
    raise MalformedMessage, "providers contain duplicate adapter keys" unless parsed.map { |provider| provider.fetch("adapter_key") }.uniq.size == parsed.size

    parsed
  end

  def parse_provider(
    body, workspace_key:, expected_adapter_key: nil, expected_auth_mode: nil, expected_execution_mode: nil
  )
    attributes = parse_json(body)
    object!(attributes, %w[protocol_version workspace_key provider], "response")
    common_response!(attributes, workspace_key:)
    provider = provider!(attributes.fetch("provider"))
    expected = [ expected_adapter_key, expected_auth_mode, expected_execution_mode ]
    if expected.any?(&:nil?) && expected.any? { |value| !value.nil? }
      raise MalformedMessage, "provider identity expectations are incomplete"
    end
    if expected.all? { |value| !value.nil? }
      equal!(provider.fetch("adapter_key"), expected_adapter_key, "provider.adapter_key")
      equal!(provider.fetch("auth_mode"), expected_auth_mode, "provider.auth_mode")
      equal!(provider.fetch("execution_mode"), expected_execution_mode, "provider.execution_mode")
    end
    provider
  end

  def parse_models(body, workspace_key:, adapter_key:, execution_mode:)
    attributes = parse_json(body)
    object!(attributes, MODEL_RESPONSE_KEYS, "response")
    common_response!(attributes, workspace_key:)
    key!(attributes.fetch("adapter_key"), "adapter_key")
    equal!(attributes.fetch("adapter_key"), adapter_key, "adapter_key")
    known_execution_mode!(attributes.fetch("execution_mode"), "execution_mode")
    equal!(attributes.fetch("execution_mode"), execution_mode, "execution_mode")
    status = attributes.fetch("status")
    unless MODEL_STATUSES.include?(status)
      raise MalformedMessage, "status is invalid"
    end
    checked_at!(attributes.fetch("checked_at"))
    models = attributes.fetch("models")
    unless models.is_a?(Array) && models.size <= MAX_MODEL_OPTIONS
      raise MalformedMessage, "models is invalid"
    end

    parsed = models.map.with_index { |model, index| model!(model, index) }
    ids = parsed.map { |model| model.fetch("id") }
    raise MalformedMessage, "models contain duplicate IDs" unless ids.uniq.size == ids.size

    defaults = parsed.count { |model| model.fetch("default") }
    raise MalformedMessage, "models contain multiple defaults" if defaults > 1

    if status == "available" && parsed.empty?
      raise MalformedMessage, "available model discovery must include models"
    end
    if %w[unsupported failed].include?(status) && parsed.any?
      raise MalformedMessage, "#{status} model discovery must not include models"
    end

    attributes.deep_dup.freeze
  end

  def parse_workspace_purge(body, workspace_key:)
    attributes = parse_json(body)
    object!(attributes, %w[protocol_version workspace_key purged], "response")
    common_response!(attributes, workspace_key:)
    equal!(attributes.fetch("purged"), true, "purged")
    true
  end

  def parse_json(body)
    raise MalformedMessage, "response body is too large" if body.bytesize > RunnerProtocol::MAX_BODY_BYTES

    JSON.parse(body)
  rescue JSON::ParserError
    raise MalformedMessage, "response body is not valid JSON"
  end
  private_class_method :parse_json

  def common_response!(attributes, workspace_key:)
    equal!(attributes.fetch("protocol_version"), VERSION, "protocol_version")
    equal!(attributes.fetch("workspace_key"), workspace_key, "workspace_key")
  end
  private_class_method :common_response!

  def provider!(provider)
    object!(provider, PROVIDER_KEYS, "provider")
    key!(provider.fetch("adapter_key"), "provider.adapter_key")
    string!(provider.fetch("name"), 100, "provider.name", blank: false)
    string!(provider.fetch("description"), 500, "provider.description")
    values!(provider.fetch("auth_modes"), "provider.auth_modes")
    boolean!(provider.fetch("model_required"), "provider.model_required")
    boolean!(provider.fetch("configured"), "provider.configured")
    boolean!(provider.fetch("secret_configured"), "provider.secret_configured")
    optional_key!(provider.fetch("auth_mode"), "provider.auth_mode")
    string!(provider.fetch("model"), 200, "provider.model")
    execution_modes!(provider.fetch("supported_execution_modes"), "provider.supported_execution_modes")
    execution_mode!(provider.fetch("execution_mode"), "provider.execution_mode")
    key!(provider.fetch("health_status"), "provider.health_status")
    boolean!(provider.fetch("available"), "provider.available")
    string!(provider.fetch("unavailable_reason"), 500, "provider.unavailable_reason")
    string!(provider.fetch("executable_version"), 200, "provider.executable_version")
    unless provider.fetch("auth_mode").blank? || provider.fetch("auth_modes").include?(provider.fetch("auth_mode"))
      raise MalformedMessage, "provider.auth_mode is unsupported"
    end

    provider.deep_dup.freeze
  end
  private_class_method :provider!

  def model!(model, index)
    name = "models[#{index}]"
    object!(model, MODEL_OPTION_KEYS, name)
    model_text!(model.fetch("id"), MAX_MODEL_ID_BYTES, "#{name}.id")
    model_text!(model.fetch("label"), MAX_MODEL_LABEL_BYTES, "#{name}.label")
    boolean!(model.fetch("default"), "#{name}.default")
    model
  end
  private_class_method :model!

  def checked_at!(value)
    valid = value.is_a?(String) && value.valid_encoding? && value.bytesize.between?(1, MAX_CHECKED_AT_BYTES)
    raise MalformedMessage, "checked_at is invalid" unless valid

    Time.iso8601(value)
  rescue ArgumentError, TypeError
    raise MalformedMessage, "checked_at is invalid"
  end
  private_class_method :checked_at!

  def model_text!(value, maximum, name)
    valid = value.is_a?(String) && value.valid_encoding? && value.bytesize.between?(1, maximum) &&
      !value.match?(/\A\p{White_Space}|\p{White_Space}\z/) &&
      !value.each_codepoint.any? { |codepoint| codepoint <= 0x1f || codepoint.between?(0x7f, 0x9f) }
    raise MalformedMessage, "#{name} is invalid" unless valid
  end
  private_class_method :model_text!

  def object!(value, keys, name)
    raise MalformedMessage, "#{name} must be an object" unless value.is_a?(Hash)
    raise MalformedMessage, "#{name} has unexpected fields" unless value.keys.sort == keys.sort
  end
  private_class_method :object!

  def equal!(value, expected, name)
    raise MalformedMessage, "#{name} does not match" unless value == expected
  end
  private_class_method :equal!

  def key!(value, name)
    raise MalformedMessage, "#{name} is invalid" unless value.is_a?(String) && value.match?(KEY_PATTERN)
  end
  private_class_method :key!

  def optional_key!(value, name)
    return if value == ""

    key!(value, name)
  end
  private_class_method :optional_key!

  def string!(value, maximum, name, blank: true)
    valid = value.is_a?(String) && value.bytesize <= maximum && (blank || value.present?)
    raise MalformedMessage, "#{name} is invalid" unless valid
  end
  private_class_method :string!

  def values!(value, name)
    valid = value.is_a?(Array) && value.size.between?(1, 4) && value.uniq.size == value.size &&
      value.all? { |item| item.is_a?(String) && item.match?(KEY_PATTERN) }
    raise MalformedMessage, "#{name} is invalid" unless valid
  end
  private_class_method :values!

  def execution_modes!(value, name)
    valid = value.is_a?(Array) && value.size <= 3 && value == value.uniq.sort &&
      value.all? { |item| item.is_a?(String) && EXECUTION_MODES.first(3).include?(item) }
    raise MalformedMessage, "#{name} is invalid" unless valid
  end
  private_class_method :execution_modes!

  def execution_mode!(value, name)
    valid = value.is_a?(String) && (value == "" || EXECUTION_MODES.include?(value))
    raise MalformedMessage, "#{name} is invalid" unless valid
  end
  private_class_method :execution_mode!

  def known_execution_mode!(value, name)
    valid = value.is_a?(String) && RuntimeInstallation::KNOWN_EXECUTION_MODES.include?(value)
    raise MalformedMessage, "#{name} is invalid" unless valid
  end
  private_class_method :known_execution_mode!

  def boolean!(value, name)
    raise MalformedMessage, "#{name} is invalid" unless value == true || value == false
  end
  private_class_method :boolean!
end
