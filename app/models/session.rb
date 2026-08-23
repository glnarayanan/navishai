class Session < ApplicationRecord
  belongs_to :user

  enum :authentication_method, { local: "local", break_glass: "break_glass" }, validate: true

  scope :active, -> { where(revoked_at: nil, expires_at: Time.current..) }

  def expired?
    expires_at <= Time.current
  end

  def revoke!
    update!(revoked_at: Time.current)
  end
end
