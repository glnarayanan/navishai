Rails.application.config.active_record.encryption.primary_key = ENV["NAVISHAI_INTEGRATION_ENCRYPTION_KEY"] if ENV["NAVISHAI_INTEGRATION_ENCRYPTION_KEY"].present?
Rails.application.config.active_record.encryption.key_derivation_salt = ENV["NAVISHAI_INTEGRATION_ENCRYPTION_SALT"] if ENV["NAVISHAI_INTEGRATION_ENCRYPTION_SALT"].present?

if Rails.env.test?
  Rails.application.config.active_record.encryption.primary_key ||= "integration-test-key-not-for-production"
  Rails.application.config.active_record.encryption.key_derivation_salt ||= "integration-test-salt-not-for-production"
end
