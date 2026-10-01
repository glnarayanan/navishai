namespace :db do
  desc "Grant the restricted navishai runtime role access after production schema preparation"
  task grant_runtime: :environment do
    abort "Runtime grants require RAILS_ENV=production." unless Rails.env.production?
    configs = ActiveRecord::Base.configurations.configs_for(env_name: "production")
    configs.each do |config|
      Navishai::DatabasePreflight.verify!(database: config.database)
      ActiveRecord::Base.establish_connection(config)
      connection = ActiveRecord::Base.connection
      role = connection.select_one("SELECT rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolbypassrls FROM pg_roles WHERE rolname = 'navishai'")
      abort "Runtime role must exist without elevated PostgreSQL privileges." unless role && role.values.none?
      owner = connection.select_value("SELECT current_user")
      abort "Run schema preparation and grants as a separate database owner, not navishai." if owner == "navishai"
      database = connection.quote_column_name(config.database)
      owner = connection.quote_column_name(owner)
      connection.transaction do
        connection.execute("REVOKE ALL ON DATABASE #{database} FROM PUBLIC")
        connection.execute("GRANT CONNECT ON DATABASE #{database} TO navishai")
        connection.execute("REVOKE CREATE ON SCHEMA public FROM PUBLIC")
        connection.execute("GRANT USAGE ON SCHEMA public TO navishai")
        connection.execute("GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO navishai")
        connection.execute("GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO navishai")
        connection.execute("ALTER DEFAULT PRIVILEGES FOR ROLE #{owner} IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO navishai")
        connection.execute("ALTER DEFAULT PRIVILEGES FOR ROLE #{owner} IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO navishai")
      end
      puts "Runtime grants prepared for #{config.name}."
    end
  ensure
    ActiveRecord::Base.connection_pool.disconnect!
  end
end
