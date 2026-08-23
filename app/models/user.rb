class User < ApplicationRecord
  has_many :memberships, dependent: :restrict_with_exception
  has_many :workspaces, through: :memberships
  has_many :sessions, dependent: :destroy
  has_many :workspace_invitations, foreign_key: :invited_by_id, dependent: :restrict_with_exception, inverse_of: :invited_by
  has_many :audit_events, foreign_key: :actor_id, dependent: :restrict_with_exception, inverse_of: :actor

  has_secure_password

  generates_token_for :password_reset, expires_in: 15.minutes do
    Digest::SHA256.hexdigest(password_salt.last(10))
  end

  generates_token_for :email_verification, expires_in: 2.days do
    [ email_address, verified_at ]
  end

  normalizes :email_address, with: ->(email) { email.strip.downcase }

  validates :password, length: { minimum: 12 }, allow_nil: true
  validates :email_address,
    presence: true,
    length: { maximum: 254 },
    format: { with: URI::MailTo::EMAIL_REGEXP },
    uniqueness: { case_sensitive: false }

  def verified?
    verified_at.present?
  end

  def sign_in_allowed?
    verified? && !break_glass?
  end
end
