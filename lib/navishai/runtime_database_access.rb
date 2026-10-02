module Navishai
  module RuntimeDatabaseAccess
    def self.grant!(connection, runtime_role: "navishai")
      role = connection.select_one("SELECT rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolbypassrls FROM pg_roles WHERE rolname = #{connection.quote(runtime_role)}")
      raise "Runtime role must exist without elevated PostgreSQL privileges." unless role && role.values.none?
      owner = connection.select_value("SELECT current_user")
      raise "Run schema preparation and grants as a separate database owner." if owner == runtime_role
      database = connection.quote_column_name(connection.select_value("SELECT current_database()"))
      owner = connection.quote_column_name(owner)
      runtime = connection.quote_column_name(runtime_role)
      connection.transaction do
        connection.execute("REVOKE ALL ON DATABASE #{database} FROM PUBLIC")
        connection.execute("GRANT CONNECT ON DATABASE #{database} TO #{runtime}")
        connection.execute("REVOKE CREATE ON SCHEMA public FROM PUBLIC")
        connection.execute("GRANT USAGE ON SCHEMA public TO #{runtime}")
        connection.execute("GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO #{runtime}")
        connection.execute("GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO #{runtime}")
        connection.execute("ALTER DEFAULT PRIVILEGES FOR ROLE #{owner} IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO #{runtime}")
        connection.execute("ALTER DEFAULT PRIVILEGES FOR ROLE #{owner} IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO #{runtime}")
      end
    end
  end
end
