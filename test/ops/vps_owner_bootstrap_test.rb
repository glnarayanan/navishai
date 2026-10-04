require "test_helper"
require_relative "../../ops/vps/bootstrap_owner"

class VpsOwnerBootstrapTest < ActiveSupport::TestCase
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
