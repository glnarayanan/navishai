class SystemMailConfiguration
  REQUIRED = %w[NAVISHAI_SYSTEM_SMTP_ADDRESS NAVISHAI_SYSTEM_SMTP_PORT NAVISHAI_SYSTEM_SMTP_USER_NAME NAVISHAI_SYSTEM_SMTP_PASSWORD].freeze

  def self.status(env = ENV)
    values = REQUIRED.to_h { |key| [ key, env[key].to_s ] }
    return :skipped if values.values.all?(&:empty?)
    port = Integer(values.fetch("NAVISHAI_SYSTEM_SMTP_PORT"), exception: false)
    return :invalid unless values.values.all?(&:present?) && port&.between?(1, 65_535)

    :configured
  end

  def self.smtp_settings(env = ENV)
    return unless status(env) == :configured

    { address: env.fetch("NAVISHAI_SYSTEM_SMTP_ADDRESS"), port: Integer(env.fetch("NAVISHAI_SYSTEM_SMTP_PORT")), user_name: env.fetch("NAVISHAI_SYSTEM_SMTP_USER_NAME"), password: env.fetch("NAVISHAI_SYSTEM_SMTP_PASSWORD"), authentication: :plain, enable_starttls: true, enable_starttls_auto: false, openssl_verify_mode: "peer" }
  end
end
