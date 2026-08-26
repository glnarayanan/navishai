class WorkspaceInvitation < ApplicationRecord
  class AcceptanceError < StandardError; end
  class AuthenticationRequired < AcceptanceError; end

  STATUSES = %w[pending accepted revoked expired].freeze

  belongs_to :workspace
  belongs_to :invited_by, class_name: "User"
  belongs_to :accepted_by, class_name: "User", optional: true

  has_secure_token :token_nonce

  enum :status, STATUSES.index_by(&:itself), validate: true
  enum :role, Membership::ROLES.index_by(&:itself), validate: true

  scope :expired_pending, -> { pending.where(expires_at: ..Time.current) }

  normalizes :email_address, with: ->(email) { email.strip.downcase }

  validates :email_address,
    presence: true,
    length: { maximum: 254 },
    format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :email_address, uniqueness: {
    scope: :workspace_id,
    case_sensitive: false,
    conditions: -> { pending }
  }
  validate :email_is_not_already_a_member, if: :pending?

  before_validation :set_expiry, on: :create

  generates_token_for :acceptance, expires_in: 7.days do
    [ email_address, role, status, token_nonce ]
  end

  def accept!(user: nil, password: nil, password_confirmation: nil)
    with_lock do
      raise AcceptanceError, "invitation has expired" if expires_at <= Time.current
      raise AcceptanceError, "invitation is no longer pending" unless pending?

      workspace.with_lock do
        raise AcceptanceError, "workspace is no longer active" if workspace.deletion_requested?

        accepted_user = resolve_user(user, password, password_confirmation)
        raise AcceptanceError, "user is already a member" if workspace.memberships.exists?(user: accepted_user)

        workspace.memberships.create!(user: accepted_user, role: role)
        update!(status: :accepted, accepted_by: accepted_user, accepted_at: Time.current)
        accepted_user
      end
    end
  end

  def revoke!
    with_lock { update!(status: :revoked) if pending? }
  end

  def expire_if_needed!
    update!(status: :expired) if pending? && expires_at <= Time.current
  end

  def self.expire_pending!
    expired_pending.update_all(status: "expired", updated_at: Time.current)
  end

  private
    def set_expiry
      self.expires_at ||= 7.days.from_now
    end

    def resolve_user(user, password, password_confirmation)
      if user
        raise AcceptanceError, "signed-in email does not match invitation" unless user.email_address == email_address

        return user
      end

      lock_account_creation
      raise AuthenticationRequired, "existing user must sign in" if User.exists?(email_address: email_address)

      User.create!(
        email_address: email_address,
        password: password,
        password_confirmation: password_confirmation,
        verified_at: Time.current
      )
    end

    def lock_account_creation
      lock_name = self.class.connection.quote("navishai-user-email-#{email_address}")
      self.class.connection.execute("SELECT pg_advisory_xact_lock(hashtext(#{lock_name}))")
    end

    def email_is_not_already_a_member
      return unless workspace&.users&.exists?(email_address: email_address)

      errors.add(:email_address, "is already a workspace member")
    end
end
