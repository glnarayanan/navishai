class OidcIdentity < ApplicationRecord
  belongs_to :user

  validates :issuer, presence: true, length: { maximum: 2_048 }
  validates :subject, presence: true, length: { maximum: 255 }, uniqueness: { scope: :issuer }
end
