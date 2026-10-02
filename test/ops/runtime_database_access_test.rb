require_relative "../../config/boot"
require "active_record"
require "minitest/autorun"
require_relative "../../ops/database_recovery"
require_relative "../../lib/navishai/runtime_database_access"
require_relative "../test_helpers/http_target_test_helper"

class RuntimeDatabaseAccessTest < Minitest::Test
  include HttpTargetTestHelper

  def setup
    @previous_configuration = ActiveRecord::Base.connection_handler.retrieve_connection_pool(ActiveRecord::Base.connection_specification_name)&.db_config
    configuration = @previous_configuration
    if !configuration && ENV["DATABASE_URL"]
      configuration = ActiveRecord::DatabaseConfigurations::UrlConfig.new("test", "primary", ENV.fetch("DATABASE_URL"), {})
    end
    @test_administrator = (configuration&.configuration_hash || {}).slice(:host, :port, :username, :password)
    @recovery = Operations::DatabaseRecovery.new(administrator: @test_administrator)
    @recovery.create!
    ActiveRecord::Base.establish_connection(@recovery.configuration)
    @connection = ActiveRecord::Base.connection
    @connection.execute("SET ROLE #{PG::Connection.quote_ident(@recovery.owner)}")
    @connection.execute("CREATE TABLE records (id bigserial PRIMARY KEY, marker text NOT NULL)")
  end

  def teardown
    @recovery&.close
  ensure
    if @previous_configuration
      ActiveRecord::Base.establish_connection(@previous_configuration)
    else
      ActiveRecord::Base.remove_connection
    end
    restored = ActiveRecord::Base.connection_handler.retrieve_connection_pool(ActiveRecord::Base.connection_specification_name)&.db_config
    assert @previous_configuration.equal?(restored), "Ops teardown must restore the previous Base connection configuration"
  end

  def grant
    Navishai::RuntimeDatabaseAccess.grant!(@connection, runtime_role: @recovery.runtime)
  end

  def test_uses_declared_test_administrator_and_port
    configuration = @recovery.configuration
    assert_equal @test_administrator[:host] || "/var/run/postgresql", configuration.fetch(:host)
    assert_equal @test_administrator[:username] || Etc.getpwuid.name, @connection.select_value("SELECT session_user")
    assert_equal @test_administrator[:port] || 5432, configuration.fetch(:port)
    assert_equal configuration.fetch(:port), @recovery.configuration(as_runtime: true).fetch(:port)
    assert_equal configuration.fetch(:username), @recovery.tool("psql", "-X", "-At", "-d", configuration.fetch(:database), "-c", "SELECT session_user").strip
    PG.connect(@recovery.url) do |connection|
      assert_equal configuration.fetch(:username), connection.exec("SELECT session_user").getvalue(0, 0)
    end
  end

  def test_rejects_nonlocal_administrator_before_connecting
    error = assert_raises(ArgumentError) { Operations::DatabaseRecovery.new(administrator: { host: "remote.invalid" }) }
    assert_includes error.message, "fixed local socket or loopback"
  end

  def test_tools_do_not_forward_or_report_administrator_password
    assert_equal "false", @recovery.tool("ruby", "-e", "print ENV.key?('PGPASSWORD')")
    secret = @test_administrator[:password] || @recovery.configuration(as_runtime: true).fetch(:password)
    failed = Struct.new(:success?).new(false)
    with_test_method(Open3, :capture2e, ->(*) { [ "private failure #{secret}", failed ] }) do
      error = assert_raises(RuntimeError) { @recovery.tool("psql", "-d", "postgres") }
      refute error.message.include?(secret)
      assert_includes error.message, "<REDACTED>"
    end
  end

  def test_grants_actual_runtime_dml_and_sequences_not_ownership_or_create
    grant
    ActiveRecord::Base.establish_connection(@recovery.configuration(as_runtime: true))
    connection = ActiveRecord::Base.connection
    assert_equal @recovery.runtime, connection.select_value("SELECT session_user")
    assert_equal 1, connection.select_value("INSERT INTO records (marker) VALUES ('asymmetric proof') RETURNING id")
    assert_equal "asymmetric proof", connection.select_value("SELECT marker FROM records WHERE id=1")
    connection.execute("UPDATE records SET marker='changed' WHERE id=1")
    assert_equal "changed", connection.select_value("SELECT marker FROM records WHERE id=1")
    connection.execute("DELETE FROM records WHERE id=1")
    assert_equal 0, connection.select_value("SELECT count(*) FROM records")
    refute connection.select_value("SELECT has_schema_privilege(current_user, 'public', 'CREATE')")
    refute connection.select_value("SELECT has_database_privilege(current_user, current_database(), 'CREATE')")
    refute_equal @recovery.runtime, connection.select_value("SELECT relowner::regrole::text FROM pg_class WHERE relname='records'")
    config = @recovery.configuration(as_runtime: true)
    error = assert_raises(PG::ConnectionBad) do
      PG.connect(host: config.fetch(:host), port: config.fetch(:port), dbname: config.fetch(:database), user: @recovery.owner, password: config.fetch(:password)) { }
    end
    assert_includes error.message, "password authentication failed"
  end

  def test_rejects_elevated_runtime_before_any_grants
    @recovery.admin.exec("ALTER ROLE #{PG::Connection.quote_ident(@recovery.runtime)} CREATEDB")
    error = assert_raises(RuntimeError) { grant }
    assert_includes error.message, "without elevated"
    refute @connection.select_value("SELECT has_table_privilege(#{@connection.quote(@recovery.runtime)}, 'records', 'SELECT')")
  end

  def test_rejects_owner_as_runtime_and_missing_role
    error = assert_raises(RuntimeError) { Navishai::RuntimeDatabaseAccess.grant!(@connection, runtime_role: @recovery.owner) }
    assert_includes error.message, "separate database owner"
    assert_raises(RuntimeError) { Navishai::RuntimeDatabaseAccess.grant!(@connection, runtime_role: "#{@recovery.runtime}_absent") }
  end

  def test_acl_snapshot_detects_missing_default_privileges
    grant
    before = @recovery.snapshot("primary")
    @connection.execute("ALTER DEFAULT PRIVILEGES FOR ROLE #{PG::Connection.quote_ident(@recovery.owner)} IN SCHEMA public REVOKE SELECT ON TABLES FROM #{PG::Connection.quote_ident(@recovery.runtime)}")
    after = @recovery.snapshot("primary")
    assert_equal before.fetch(:rows), after.fetch(:rows)
    refute_equal before.fetch(:acl), after.fetch(:acl)
  end
end
