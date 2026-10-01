# Proof-only lifecycle. No caller-supplied database or role names.
require "digest"
require "etc"
require "json"
require "open3"
require "pg"
require "securerandom"

module Operations
  class DatabaseRecovery
    attr_reader :databases, :owner, :runtime, :admin

    def initialize
      @socket = "/var/run/postgresql"
      @user = Etc.getpwuid.name
      @prefix = "navishai_ops_#{Process.pid}_#{SecureRandom.hex(6)}"
      @owner = "#{@prefix}_owner"
      @runtime = "#{@prefix}_runtime"
      @password = SecureRandom.hex(32)
      @databases = %w[primary cache queue cable].to_h { |name| [ name, "#{@prefix}_#{name}" ] }
      @created = []
      @roles = []
      @admin = PG.connect(host: @socket, user: @user, dbname: "postgres")
    end

    def create!
      create_roles!
      databases.each_value do |name|
        admin.exec("CREATE DATABASE #{PG::Connection.quote_ident(name)} OWNER #{PG::Connection.quote_ident(owner)} TEMPLATE template0")
        @created << name
      end
    end

    def create_roles!
      [ owner, runtime ].each do |name|
        admin.exec("CREATE ROLE #{PG::Connection.quote_ident(name)} LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD #{admin.escape_literal(@password)}")
        @roles << name
      end
    end

    def configuration(name = "primary", as_runtime: false)
      if as_runtime
        { adapter: "postgresql", host: "127.0.0.1", username: runtime, password: @password, database: databases.fetch(name) }
      else
        { adapter: "postgresql", host: @socket, username: @user, database: databases.fetch(name) }
      end
    end

    def url
      "postgresql:///#{databases.fetch('primary')}?host=#{@socket}&user=#{@user}"
    end

    def connect(name)
      connection = PG.connect(host: @socket, user: @user, dbname: databases.fetch(name))
      yield connection
    ensure
      connection&.close
    end

    def tool(*command, input: "")
      output, status = Open3.capture2e({ "PATH" => ENV.fetch("PATH"), "HOME" => "/tmp" }, *command,
        stdin_data: input, unsetenv_others: true)
      raise "PostgreSQL tool failed: #{output.gsub(@password, '<REDACTED>')}" unless status.success?
      output
    end

    def load_structure!(path)
      tool("psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-h", @socket, "-U", @user, "-d", databases.fetch("primary"),
        input: "SET ROLE #{PG::Connection.quote_ident(owner)};\n#{File.read(path)}")
    end

    def prepare_auxiliary!(root, analysis:)
      %w[cache queue cable].each do |name|
        ActiveRecord::Base.establish_connection(configuration(name))
        ActiveRecord::Base.connection.execute("SET ROLE #{PG::Connection.quote_ident(owner)}")
        load File.join(root, "db/#{name}_schema.rb")
      end
      connect("cache") do |db|
        db.exec_params("INSERT INTO solid_cache_entries (key, value, created_at, key_hash, byte_size) VALUES ($1, $2, CURRENT_TIMESTAMP, 76543, 20)", [ "synthetic-cache", "synthetic cached bytes" ])
      end
      connect("queue") do |db|
        arguments = CorpusAnalysisJob.new(analysis.id).serialize.to_json
        row = db.exec_params("INSERT INTO solid_queue_jobs (queue_name, class_name, arguments, priority, active_job_id, scheduled_at, created_at, updated_at) VALUES ('default', 'CorpusAnalysisJob', $1, 3, $2, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP) RETURNING id", [ arguments, SecureRandom.uuid ])
        db.exec_params("INSERT INTO solid_queue_ready_executions (job_id, queue_name, priority, created_at) VALUES ($1, 'default', 3, CURRENT_TIMESTAMP)", [ row.getvalue(0, 0) ])
      end
      connect("cable") do |db|
        db.exec_params("INSERT INTO solid_cable_messages (channel, payload, created_at, channel_hash) VALUES ($1, $2, CURRENT_TIMESTAMP, 98765)", [ "synthetic-channel", "synthetic broadcast bytes" ])
      end
      grant!
      ActiveRecord::Base.establish_connection(configuration)
    end

    def grant!
      require_relative "../lib/navishai/runtime_database_access"
      databases.each_key do |name|
        ActiveRecord::Base.establish_connection(configuration(name))
        connection = ActiveRecord::Base.connection
        connection.execute("SET ROLE #{PG::Connection.quote_ident(owner)}")
        Navishai::RuntimeDatabaseAccess.grant!(connection, runtime_role: runtime)
      end
      ActiveRecord::Base.connection_pool.disconnect!
    end

    def snapshot(name)
      connect(name) do |db|
        rows = db.exec("SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename").to_h do |row|
          table = PG::Connection.quote_ident(row.fetch("tablename"))
          data = db.exec("SELECT COALESCE(jsonb_agg(row ORDER BY row::text), '[]'::jsonb)::text FROM (SELECT to_jsonb(t) AS row FROM #{table} t) records").getvalue(0, 0)
          [ table, Digest::SHA256.hexdigest(data) ]
        end
        acl = [
          "SELECT datdba::regrole::text, datacl::text FROM pg_database WHERE datname=current_database()",
          "SELECT nspname, nspowner::regrole::text, nspacl::text FROM pg_namespace WHERE nspname='public'",
          "SELECT relname, relowner::regrole::text, relacl::text FROM pg_class WHERE relnamespace='public'::regnamespace ORDER BY relname",
          "SELECT defaclrole::regrole::text, defaclnamespace::regnamespace::text, defaclobjtype, defaclacl::text FROM pg_default_acl ORDER BY 1,2,3"
        ].map { |sql| db.exec(sql).values }
        { rows:, acl: }
      end
    end

    def role_snapshot
      admin.exec_params("SELECT rolname, rolsuper, rolinherit, rolcreaterole, rolcreatedb, rolcanlogin, rolreplication, rolbypassrls, rolconnlimit FROM pg_roles WHERE rolname IN ($1, $2) ORDER BY rolname", [ owner, runtime ]).values
    end

    def backup!(directory)
      manifest = File.join(directory, "roles.json")
      File.write(manifest, JSON.generate(role_snapshot), perm: 0o600)
      expected = databases.keys.to_h { |name| [ name, snapshot(name) ] }
      databases.each do |name, database|
        tool("pg_dump", "-h", @socket, "-U", @user, "-d", database, "--format=custom", "--create", "--file", File.join(directory, "#{name}.dump"))
        File.chmod(0o600, File.join(directory, "#{name}.dump"))
      end
      expected
    end

    def restore!(directory, expected: nil)
      expected ||= backup!(directory)
      # Model full local loss, not an in-place overwrite. Drop only our own names.
      drop_assets!
      create_roles!
      raise "Restored role flags differ" unless role_snapshot == JSON.parse(File.read(File.join(directory, "roles.json")))
      databases.each do |name, database|
        # Record only the exact name that this archive is permitted to create.
        @created << database
        tool("pg_restore", "-h", @socket, "-U", @user, "-d", "postgres", "--create", "--exit-on-error", File.join(directory, "#{name}.dump"))
        raise "Restored #{name} rows, owners or ACLs differ" unless snapshot(name) == expected.fetch(name)
      end
      puts "PASS: four complete database fingerprints, database/schema/table/sequence/default ACLs, separate recreated non-elevated owner/runtime roles; no --no-owner/--no-acl."
    end

    def verify_runtime!
      databases.each_key do |name|
        ActiveRecord::Base.establish_connection(configuration(name, as_runtime: true))
        connection = ActiveRecord::Base.connection
        raise "Runtime login identity" unless connection.select_value("SELECT current_user = session_user") && connection.select_value("SELECT current_user") == runtime
        %w[rolsuper rolcreatedb rolcreaterole rolreplication rolbypassrls].each do |flag|
          raise "Elevated runtime" if connection.select_value("SELECT #{flag} FROM pg_roles WHERE rolname = current_user")
        end
        table = { "primary" => "corpora", "cache" => "solid_cache_entries", "queue" => "solid_queue_jobs", "cable" => "solid_cable_messages" }.fetch(name)
        raise "Missing restored runtime data" unless connection.select_value("SELECT count(*) FROM #{table}").positive?
        [ "CREATE TABLE forbidden_proof (id integer)", "ALTER TABLE #{table} DISABLE TRIGGER ALL", "CREATE DATABASE forbidden_proof", "CREATE ROLE forbidden_proof", "SET ROLE #{PG::Connection.quote_ident(owner)}" ].each do |sql|
          begin
            connection.execute(sql)
            raise "Runtime accepted #{sql}"
          rescue ActiveRecord::StatementInvalid => error
            raise unless error.cause.is_a?(PG::InsufficientPrivilege)
          end
        end
        inserts = {
          "cache" => "INSERT INTO solid_cache_entries (key, value, created_at, key_hash, byte_size) VALUES ('post-restore-cache', 'bytes', CURRENT_TIMESTAMP, 87654, 5) RETURNING id",
          "queue" => "INSERT INTO solid_queue_jobs (queue_name, class_name, arguments, priority, scheduled_at, created_at, updated_at) SELECT 'default', class_name, arguments, 3, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP FROM solid_queue_jobs ORDER BY id LIMIT 1 RETURNING id",
          "cable" => "INSERT INTO solid_cable_messages (channel, payload, created_at, channel_hash) VALUES ('post-restore-channel', 'bytes', CURRENT_TIMESTAMP, 87654) RETURNING id"
        }
        if inserts.key?(name)
          maximum = connection.select_value("SELECT max(id) FROM #{table}")
          inserted = connection.select_value(inserts.fetch(name))
          raise "Restored #{name} sequence did not advance" unless inserted > maximum
          connection.execute("DELETE FROM #{table} WHERE id=#{inserted}")
        end
        # Prove default ACLs survive: an owner-created post-restore sequence/table
        # permits runtime inserts, but never gives it schema/table ownership.
        connect(name) do |db|
          db.exec("SET ROLE #{PG::Connection.quote_ident(owner)}")
          db.exec("CREATE TABLE runtime_grant_probe (id bigserial PRIMARY KEY, marker text NOT NULL)")
        end
        raise "Restored default sequence/table grants" unless connection.select_value("INSERT INTO runtime_grant_probe (marker) VALUES ('synthetic only') RETURNING id") == 1
        connection.execute("DELETE FROM runtime_grant_probe")
      end
      ActiveRecord::Base.establish_connection(configuration(as_runtime: true))
      puts "PASS: real password-authenticated runtime logins across four databases, 20 privilege denials, restored current and future table/sequence DML grants."
    end

    def drop_assets!
      @created.reverse_each do |name|
        admin.exec("DROP DATABASE IF EXISTS #{PG::Connection.quote_ident(name)}")
      end
      @created.clear
      @roles.reverse_each { |name| admin.exec("DROP ROLE #{PG::Connection.quote_ident(name)}") }
      @roles.clear
    end

    def close
      ActiveRecord::Base.connection_pool.disconnect! if defined?(ActiveRecord::Base)
      drop_assets!
      admin.close
    end
  end
end
