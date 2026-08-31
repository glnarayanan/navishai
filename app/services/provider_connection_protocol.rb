module ProviderConnectionProtocol
  VERSION = "v1"
  CATALOG_PATH = "/v1/providers/catalog"
  CONFIGURE_PATH = "/v1/providers/configure"
  REMOVE_PATH = "/v1/providers/remove"
  PURGE_WORKSPACE_PATH = "/v1/providers/purge-workspace"
  PROVIDER_KEYS = %w[
    adapter_key name description auth_modes model_required configured secret_configured auth_mode model
    health_status available executable_version
  ].freeze
  KEY_PATTERN = /\A[a-z][a-z0-9_]{0,63}\z/

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

  def parse_provider(body, workspace_key:)
    attributes = parse_json(body)
    object!(attributes, %w[protocol_version workspace_key provider], "response")
    common_response!(attributes, workspace_key:)
    provider!(attributes.fetch("provider"))
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
    key!(provider.fetch("health_status"), "provider.health_status")
    boolean!(provider.fetch("available"), "provider.available")
    string!(provider.fetch("executable_version"), 200, "provider.executable_version")
    unless provider.fetch("auth_mode").blank? || provider.fetch("auth_modes").include?(provider.fetch("auth_mode"))
      raise MalformedMessage, "provider.auth_mode is unsupported"
    end

    provider.deep_dup.freeze
  end
  private_class_method :provider!

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

  def boolean!(value, name)
    raise MalformedMessage, "#{name} is invalid" unless value == true || value == false
  end
  private_class_method :boolean!
end
