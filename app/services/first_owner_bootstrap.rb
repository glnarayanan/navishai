class FirstOwnerBootstrap
  class Unavailable < StandardError; end

  LOCK_KEY = "navishai-first-owner-bootstrap"

  def self.available?
    ENV["NAVISHAI_BOOTSTRAP_TOKEN"].to_s.bytesize >= 32 &&
      !InstallationState.exists? && !User.exists? && !Organization.exists?
  end

  def self.valid_token?(candidate)
    expected = ENV["NAVISHAI_BOOTSTRAP_TOKEN"].to_s
    return false if candidate.blank? || expected.bytesize < 32

    ActiveSupport::SecurityUtils.secure_compare(
      Digest::SHA256.hexdigest(candidate),
      Digest::SHA256.hexdigest(expected)
    )
  end

  def self.call(organization_name:, organization_slug:, workspace_name:, workspace_slug:, email_address:, password:, password_confirmation:)
    ApplicationRecord.transaction do
      ApplicationRecord.connection.execute("SELECT pg_advisory_xact_lock(hashtext('#{LOCK_KEY}'))")
      raise Unavailable if InstallationState.exists? || User.exists? || Organization.exists?

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
