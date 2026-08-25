namespace :navishai do
  namespace :break_glass do
    desc "Create or reset the local break-glass Admin for one workspace"
    task create: :environment do
      required = %w[ORGANIZATION_SLUG WORKSPACE_SLUG EMAIL PASSWORD]
      missing = required.select { |name| ENV[name].blank? }
      abort "Missing: #{missing.join(', ')}" if missing.any?

      organization = Organization.find_by!(slug: ENV.fetch("ORGANIZATION_SLUG"))
      workspace = organization.workspaces.find_by!(slug: ENV.fetch("WORKSPACE_SLUG"))

      User.transaction do
        user = User.find_by(break_glass: true) || User.new(break_glass: true)
        user.lock! if user.persisted?
        if (email_owner = User.find_by(email_address: ENV.fetch("EMAIL"))) && email_owner != user
          abort "EMAIL belongs to a regular user"
        end

        user.update!(
          email_address: ENV.fetch("EMAIL"),
          password: ENV.fetch("PASSWORD"),
          password_confirmation: ENV.fetch("PASSWORD"),
          verified_at: Time.current
        )
        user.sessions.active.update_all(revoked_at: Time.current)
        user.memberships.where.not(workspace: workspace).delete_all
        membership = workspace.memberships.find_or_initialize_by(user: user)
        membership.role = :admin
        membership.save!
        AuditEvent.record!(
          action: "break_glass.configured",
          source: :task,
          workspace: workspace,
          actor: user,
          subject: membership
        )
      end

      puts "Break-glass Admin is ready for #{organization.slug}/#{workspace.slug}."
    end
  end
end
