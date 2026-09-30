require_relative "../navishai/database_preflight"

Rake::Task["db:load_config"].enhance do
  Navishai::DatabasePreflight.check_configurations!
end
