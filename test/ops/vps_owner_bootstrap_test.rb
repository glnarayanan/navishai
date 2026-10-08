require "test_helper"
require_relative "../test_helpers/http_target_test_helper"
require_relative "../../ops/vps/bootstrap_owner"

class VpsOwnerBootstrapTest < ActiveSupport::TestCase
  include HttpTargetTestHelper

  setup do
    @token = ENV["NAVISHAI_BOOTSTRAP_TOKEN"]
    @expiry = ENV["NAVISHAI_BOOTSTRAP_TOKEN_EXPIRES_AT"]
    ENV["NAVISHAI_BOOTSTRAP_TOKEN"] = "t" * 48
    ENV["NAVISHAI_BOOTSTRAP_TOKEN_EXPIRES_AT"] = 1.hour.from_now.iso8601
    InstallationState.delete_all
    WorkspaceInvitation.delete_all
    Session.delete_all
    Membership.delete_all
    Workspace.delete_all
    Organization.delete_all
    User.delete_all
    @data = { organization_name: "Installer Org", organization_slug: "installer-org",
      workspace_name: "Support Lab", workspace_slug: "support-lab", email_address: "installer@example.com",
      password: "installer-private-password", password_confirmation: "installer-private-password" }
    @output = StringIO.new
    @errors = StringIO.new
  end

  teardown do
    ENV["NAVISHAI_BOOTSTRAP_TOKEN"] = @token
    ENV["NAVISHAI_BOOTSTRAP_TOKEN_EXPIRES_AT"] = @expiry
  end

  test "creates a verified real Owner and attributable audit exactly once" do
    assert run_bootstrap
    user = User.sole
    assert user.authenticate(@data[:password])
    assert user.verified?
    assert_equal "owner", user.memberships.sole.role
    audit = AuditEvent.find_by!(action: "installation.bootstrapped", actor: user)
    assert_equal user.workspaces.sole, audit.workspace
    assert_equal "task", audit.source
    assert_equal "Workspace", audit.subject_type
    assert_equal audit.workspace_id, audit.subject_id
    assert_equal({}, audit.metadata)
    assert_no_difference [ "User.count", "AuditEvent.count" ] do
      assert run_bootstrap
    end
    assert_includes @output.string, "already bootstrapped"
    refute_includes @output.string + @errors.string, @data[:password]
  end

  test "expired malformed absent and short tokens cannot bypass service availability" do
    [ [ "t" * 48, 1.second.ago.iso8601 ], [ "t" * 48, "invalid" ], [ "", 1.hour.from_now.iso8601 ], [ "short", 1.hour.from_now.iso8601 ] ].each do |token, expiry|
      ENV["NAVISHAI_BOOTSTRAP_TOKEN"] = token
      ENV["NAVISHAI_BOOTSTRAP_TOKEN_EXPIRES_AT"] = expiry
      assert_no_difference [ "User.count", "InstallationState.count", "AuditEvent.count" ] do
        refute run_bootstrap
      end
    end
  end

  test "rejects invalid password confirmation and unknown duplicate or malformed input atomically" do
    [ @data.merge(password: "short"), @data.merge(password_confirmation: "different"),
      @data.merge(command: "puts ENV"), @data.except(:password) ].each do |data|
      assert_no_difference [ "Organization.count", "User.count", "AuditEvent.count" ] do
        refute run_bootstrap(JSON.generate(data))
      end
    end
    refute run_bootstrap(JSON.generate(@data).sub("{", '{"password":"duplicate",'))
    refute run_bootstrap("not json")
    refute_includes @errors.string, @data[:password]
  end

  test "does not renew or recreate owner after installation marker remains" do
    InstallationState.create!(bootstrapped_at: Time.current)
    ENV["NAVISHAI_BOOTSTRAP_TOKEN_EXPIRES_AT"] = 1.second.ago.iso8601
    assert_no_difference "User.count" do
      assert run_bootstrap
    end
    assert_includes @output.string, "sign in"
  end

  test "inactive token names renewal without exposing the token or account" do
    ENV["NAVISHAI_BOOTSTRAP_TOKEN_EXPIRES_AT"] = 1.second.ago.iso8601
    refute run_bootstrap
    assert_includes @errors.string, "protected bootstrap token is inactive"
    assert_includes @errors.string, "sudo navishai renew-bootstrap"
    refute_includes @errors.string, ENV["NAVISHAI_BOOTSTRAP_TOKEN"]
    refute_includes @errors.string, @data[:email_address]
  end

  test "account validation identifies only fixed field names and rolls back all writes" do
    [ [ { password_confirmation: "different-private-password" }, "Owner", "password_confirmation" ],
      [ { organization_slug: "INVALID_PRIVATE_ORG" }, "Organisation", "slug" ],
      [ { workspace_slug: "INVALID_PRIVATE_WORKSPACE" }, "Workspace", "slug" ] ].each do |changes, label, field|
      @errors.truncate(0)
      @errors.rewind
      assert_no_difference [ "Organization.count", "Workspace.count", "User.count", "InstallationState.count", "AuditEvent.count" ] do
        refute run_bootstrap(JSON.generate(@data.merge(changes)))
      end
      assert_includes @errors.string, "#{label} fields need correction: #{field}"
      changes.each_value { |value| refute_includes @errors.string, value }
      refute_includes @errors.string, @data[:password]
      refute_includes @errors.string, "renew-bootstrap"
    end
  end

  test "malformed input and database errors have distinct redacted diagnostics" do
    refute run_bootstrap("not json")
    assert_includes @errors.string, "invalid account input"
    @errors.truncate(0)
    @errors.rewind
    failure = ActiveRecord::StatementInvalid.new("SQL contains #{@data[:password]} #{ENV['NAVISHAI_BOOTSTRAP_TOKEN']}")
    with_test_method(ApplicationRecord, :transaction, ->(*) { raise failure }) do
      refute run_bootstrap
    end
    assert_includes @errors.string, "database operation failed"
    refute_includes @errors.string, @data[:password]
    refute_includes @errors.string, ENV["NAVISHAI_BOOTSTRAP_TOKEN"]
    refute_includes @errors.string, "renew-bootstrap"
  end

  test "failed audit validation rolls back Owner creation and does not blame account fields" do
    audit = AuditEvent.new
    audit.errors.add(:metadata, @data[:password])
    with_test_method(AuditEvent, :record!, ->(**) { raise ActiveRecord::RecordInvalid, audit }) do
      assert_no_difference [ "Organization.count", "Workspace.count", "User.count", "InstallationState.count", "AuditEvent.count" ] do
        refute run_bootstrap
      end
    end
    assert_includes @errors.string, "account/audit validation failed"
    refute_includes @errors.string, @data[:password]
    refute_includes @errors.string, "fields need correction"
  end

  test "real DEBUG logger retains no credentials and is restored" do
    previous = ActiveRecord::Base.logger
    log = StringIO.new
    logger = ActiveSupport::Logger.new(log)
    logger.level = Logger::DEBUG
    ActiveRecord::Base.logger = logger
    assert run_bootstrap
    assert_same logger, ActiveRecord::Base.logger
    refute_includes log.string, @data[:password]
    refute_includes log.string, ENV["NAVISHAI_BOOTSTRAP_TOKEN"]
  ensure
    ActiveRecord::Base.logger = previous
  end

  private
    def run_bootstrap(json = JSON.generate(@data))
      VpsOwnerBootstrap.run(input: StringIO.new(json), output: @output, errors: @errors)
    end
end
