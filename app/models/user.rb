class User < ApplicationRecord
  has_many :memberships, dependent: :restrict_with_exception
  has_many :workspaces, through: :memberships

  normalizes :email_address, with: ->(email) { email.strip.downcase }

  validates :email_address,
    presence: true,
    length: { maximum: 254 },
    format: { with: URI::MailTo::EMAIL_REGEXP },
    uniqueness: { case_sensitive: false }
end
