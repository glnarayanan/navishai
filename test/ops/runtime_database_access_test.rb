require_relative "../../config/boot"
require "active_record"
require "minitest/autorun"
require_relative "../../ops/database_recovery"
require_relative "../../lib/navishai/runtime_database_access"

class RuntimeDatabaseAccessTest < Minitest::Test
  def setup
    @recovery = Operations::DatabaseRecovery.new
    @recovery.create!
    ActiveRecord::Base.establish_connection(@recovery.configuration)
    @connection = ActiveRecord::Base.connection
    @connection.execute("SET ROLE #{PG::Connection.quote_ident(@recovery.owner)}")
    @connection.execute("CREATE TABLE records (id bigserial PRIMARY KEY, marker text NOT NULL)")
  end

  def teardown
    @recovery&.close
  end

  def grant
    Navishai::RuntimeDatabaseAccess.grant!(@connection, runtime_role: @recovery.runtime)
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
      PG.connect(host: config.fetch(:host), dbname: config.fetch(:database), user: @recovery.owner, password: config.fetch(:password)) { }
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
