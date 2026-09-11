class FirstOwnerBootstrap
  class Unavailable < StandardError; end

  LOCK_KEY = "navishai-first-owner-bootstrap"

  def self.available?
    token_active? && renewable?
  end

  # A deployment may issue a fresh bootstrap token only while nothing has been
  # bootstrapped; after the first Owner exists the token is never renewable.
  def self.renewable?
    !InstallationState.exists? && !User.exists? && !Organization.exists?
  end

  def self.valid_token?(candidate)
    expected = ENV["NAVISHAI_BOOTSTRAP_TOKEN"].to_s
    return false unless token_active?
    return false if candidate.blank?

    ActiveSupport::SecurityUtils.secure_compare(
      Digest::SHA256.hexdigest(candidate),
      Digest::SHA256.hexdigest(expected)
    )
  end

  def self.token_active?
    expected = ENV["NAVISHAI_BOOTSTRAP_TOKEN"].to_s
    expiry = Time.iso8601(ENV.fetch("NAVISHAI_BOOTSTRAP_TOKEN_EXPIRES_AT", ""))

    expected.bytesize >= 32 && expiry.future?
  rescue ArgumentError
    false
  end

  def self.call(organization_name:, organization_slug:, workspace_name:, workspace_slug:, email_address:, password:, password_confirmation:)
    ApplicationRecord.transaction do
      ApplicationRecord.connection.execute("SELECT pg_advisory_xact_lock(hashtext('#{LOCK_KEY}'))")
      raise Unavailable unless renewable?

      organization = Organization.create!(name: organization_name, slug: organization_slug)
      workspace = organization.workspaces.create!(name: workspace_name, slug: workspace_slug)
      user = User.create!(
        email_address: email_address,
        password: password,
        password_confirmation: password_confirmation,
        verified_at: Time.current
      )
      workspace.memberships.create!(user: user, role: :owner)
      InstallationState.create!(bootstrapped_at: Time.current)
      user
    end
  end
end
