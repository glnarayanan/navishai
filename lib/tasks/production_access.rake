require_relative "../navishai/runtime_database_access"

namespace :db do
  desc "Grant the restricted navishai runtime role access after production schema preparation"
  task grant_runtime: :environment do
    abort "Runtime grants require RAILS_ENV=production." unless Rails.env.production?
    configs = ActiveRecord::Base.configurations.configs_for(env_name: "production")
    configs.each do |config|
      Navishai::DatabasePreflight.verify!(database: config.database)
      ActiveRecord::Base.establish_connection(config)
      connection = ActiveRecord::Base.connection
      Navishai::RuntimeDatabaseAccess.grant!(connection)
      puts "Runtime grants prepared for #{config.name}."
    end
  ensure
    ActiveRecord::Base.connection_pool.disconnect!
  end
end
