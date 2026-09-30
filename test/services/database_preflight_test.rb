require "test_helper"
require "open3"

class DatabasePreflightTest < ActiveSupport::TestCase
  test "rejects old database names and helpdesk tables under a new name" do
    %w[navishai_development navishai_test navishai_test_0 navishai_production_queue].each do |database|
      assert_raises(Navishai::DatabasePreflight::LegacyDatabase) { Navishai::DatabasePreflight.verify!(database:) }
    end
    assert_raises(Navishai::DatabasePreflight::LegacyDatabase) do
      Navishai::DatabasePreflight.verify!(database: "renamed", tables: %w[users support_cases])
    end
    assert_nil Navishai::DatabasePreflight.verify!(database: "navishai_lab_test", tables: %w[users workspaces])
  end

  test "schema loading fails before connecting to an old database" do
    output, status = Open3.capture2e({ "DATABASE_URL" => "postgres:///navishai_test" }, Rails.root.join("bin/rails").to_s, "db:schema:load")
    assert_not status.success?
    assert_includes output, "Refusing an old helpdesk database"
  end
end
