class IdentityKeyNormalizer
  DOMAIN_FORMAT = /\A(?=.{1,253}\z)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/

  def self.normalize(kind, value)
    normalized = value.to_s.strip.downcase

    case kind.to_s
    when "email"
      raise ArgumentError, "invalid email identity key" if normalized.length > 254 || !normalized.match?(URI::MailTo::EMAIL_REGEXP)
    when "domain"
      normalized = normalized.delete_suffix(".")
      raise ArgumentError, "invalid domain identity key" unless normalized.ascii_only? && normalized.match?(DOMAIN_FORMAT)
    else
      raise ArgumentError, "unsupported identity key"
    end

    normalized
  end
end
