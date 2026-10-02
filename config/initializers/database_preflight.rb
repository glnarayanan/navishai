require Rails.root.join("lib/navishai/database_preflight")

# Boot checks the selected environment only; database tasks additionally check all
# configured targets before create, prepare, migrate, schema load, reset or drop.
unless ENV["SECRET_KEY_BASE_DUMMY"]
  ActiveRecord::Base.configurations.configs_for(env_name: Rails.env).each do |config|
    Navishai::DatabasePreflight.verify!(database: config.database)
  end
end
