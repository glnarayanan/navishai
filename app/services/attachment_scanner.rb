class AttachmentScanner
  Result = Data.define(:status, :code)

  class ConfigurationError < StandardError; end

  ADAPTERS = {
    "none" => ->(env) { new },
    "clamd" => ->(env) { Clamd.new(address: env["NAVISHAI_CLAMD_ADDRESS"]) }
  }.freeze

  class << self
    attr_writer :default

    def default
      @default ||= new
    end

    # Builds the deployment's scanner from NAVISHAI_ATTACHMENT_SCANNER. A blank or
    # `none` value keeps the fail-closed default that quarantines every file. An
    # unknown name raises so a misconfigured deployment stops at boot instead of
    # silently quarantining forever.
    def from_environment(env = ENV)
      name = env["NAVISHAI_ATTACHMENT_SCANNER"].to_s.strip.downcase
      name = "none" if name.empty?
      builder = ADAPTERS[name]
      raise ConfigurationError, "unknown attachment scanner #{name.inspect}; supported: #{ADAPTERS.keys.join(', ')}" unless builder

      builder.call(env)
    end
  end

  def scan(data:, content_type:, filename:)
    Result.new(status: :unavailable, code: "scanner_unavailable")
  end
end
