class SharedEmailInbox < ApplicationRecord
  CREDENTIAL_KEY_FORMAT = /\A[a-z0-9_]+\z/

  belongs_to :workspace
  has_many :email_threads, dependent: :restrict_with_exception
  has_many :inbound_email_deliveries, dependent: :restrict_with_exception
  has_many :email_message_links, dependent: :restrict_with_exception
  has_many :outbound_email_deliveries, dependent: :restrict_with_exception

  has_secure_token :webhook_key

  normalizes :name, with: ->(value) { value.strip }
  normalizes :email_address, with: ->(value) { value.strip.downcase }
  normalizes :credential_key, with: ->(value) { value.strip.downcase }

  validates :name, presence: true, length: { maximum: 100 }
  validates :email_address, presence: true, length: { maximum: 254 },
    format: { with: URI::MailTo::EMAIL_REGEXP }, uniqueness: { scope: :workspace_id }
  validates :webhook_key, presence: true, uniqueness: true
  validates :credential_key, presence: true, length: { maximum: 100 }, format: { with: CREDENTIAL_KEY_FORMAT }

  scope :active, -> { where(active: true) }

  def webhook_secret
    credential = Rails.application.credentials.dig(:shared_email, credential_key.to_sym, :webhook_secret)
    credential.presence || ENV["NAVISHAI_SHARED_EMAIL_#{credential_key.upcase}_WEBHOOK_SECRET"].presence
  end

  def webhook_ready?
    active? && webhook_secret.to_s.bytesize >= 32
  end

  def smtp_settings
    credential = Rails.application.credentials.dig(:shared_email, credential_key.to_sym, :smtp) || {}
    prefix = "NAVISHAI_SHARED_EMAIL_#{credential_key.upcase}_SMTP_"
    {
      address: credential[:address].presence || ENV["#{prefix}ADDRESS"].presence,
      port: credential[:port].presence || ENV["#{prefix}PORT"].presence,
      user_name: credential[:user_name].presence || ENV["#{prefix}USER_NAME"].presence,
      password: credential[:password].presence || ENV["#{prefix}PASSWORD"].presence,
      authentication: credential[:authentication].presence || ENV["#{prefix}AUTHENTICATION"].presence || "plain"
    }
  end
end
