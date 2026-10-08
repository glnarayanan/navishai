# Fixed Rails runner entrypoint. Account input is stdin only, never Ruby code.
require "json"

module VpsOwnerBootstrap
  class InvalidInput < StandardError; end

  FIELDS = %w[email_address password password_confirmation organization_name organization_slug workspace_name workspace_slug].freeze

  def self.run(input: $stdin, output: $stdout, errors: $stderr)
    # Suppress SQL parameter logging even on a misconfigured DEBUG deployment.
    previous_logger = ActiveRecord::Base.logger
    ActiveRecord::Base.logger = nil
    raw = input.read(16_385).to_s
    raise InvalidInput if raw.bytesize > 16_384
    data = JSON.parse(raw, allow_duplicate_key: false)
    raise InvalidInput unless data.is_a?(Hash) && data.keys.sort == FIELDS.sort && data.values.all? { |value| value.is_a?(String) && !value.empty? }

    ApplicationRecord.transaction do
      ApplicationRecord.connection.execute("SELECT pg_advisory_xact_lock(hashtext('#{FirstOwnerBootstrap::LOCK_KEY}'))")
      unless FirstOwnerBootstrap.renewable?
        output.puts "Installation already bootstrapped; sign in with your existing Owner account. No Owner created."
        return true
      end
      token = ENV["NAVISHAI_BOOTSTRAP_TOKEN"].to_s
      raise FirstOwnerBootstrap::Unavailable unless FirstOwnerBootstrap.available? && FirstOwnerBootstrap.valid_token?(token)

      user = FirstOwnerBootstrap.call(**data.transform_keys(&:to_sym))
      workspace = user.workspaces.sole
      AuditEvent.record!(action: "installation.bootstrapped", source: "task", workspace: workspace, actor: user, subject: workspace)
    end
    output.puts "Owner workspace created. Sign in using your chosen credentials."
    true
  rescue FirstOwnerBootstrap::Unavailable
    errors.puts "Owner bootstrap refused: protected bootstrap token is inactive (missing, invalid or expired). Run sudo navishai renew-bootstrap, then sudo navishai install --resume."
    false
  rescue InvalidInput, JSON::ParserError
    errors.puts "Owner bootstrap refused: invalid account input. Re-enter account details; values withheld."
    false
  rescue ActiveRecord::RecordInvalid => error
    # Only these fixed names may reach the terminal, never validation messages,
    # submitted values, SQL, exception messages or backtraces.
    label, fields = case error.record
    when User then [ "Owner", %i[email_address password password_confirmation] ]
    when Organization then [ "Organisation", %i[name slug] ]
    when Workspace then [ "Workspace", %i[name slug] ]
    else [ "Account/audit", [] ]
    end
    invalid = fields.select { |field| error.record.errors.key?(field) }
    if invalid.empty?
      errors.puts "Owner bootstrap refused: account/audit validation failed. Keep installed data and report this message; no credentials printed."
    else
      errors.puts "Owner bootstrap refused: #{label} fields need correction: #{invalid.join(', ')}. Values withheld; no account changes saved."
    end
    false
  rescue ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished
    errors.puts "Owner bootstrap refused: database operation failed. Keep installed data and report this message; no credentials printed."
    false
  rescue StandardError
    # Database and validation exceptions can contain private bind values. Never
    # expose their messages or backtraces from this credential-handling runner.
    errors.puts "Owner bootstrap refused: unexpected setup error. Keep installed data and report this message; no credentials printed."
    false
  ensure
    ActiveRecord::Base.logger = previous_logger
    data.clear if data.respond_to?(:clear)
    raw&.clear
  end
end

exit(VpsOwnerBootstrap.run ? 0 : 1) if $PROGRAM_NAME == __FILE__
