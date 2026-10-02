require "test_helper"
require "open3"

class ProductionConfigurationTest < ActiveSupport::TestCase
  test "Compose runtime never receives preparation credentials or the bootstrap role" do
    services = YAML.safe_load_file(Rails.root.join("compose.yaml"), aliases: true).fetch("services")
    %w[web jobs].each do |name|
      environment = services.fetch(name).fetch("environment")
      assert_not environment.key?("POSTGRES_PASSWORD")
      assert_not environment.key?("NAVISHAI_POSTGRES_PASSWORD")
      assert_not environment.key?("NAVISHAI_DATABASE_USERNAME")
      assert_includes environment.fetch("NAVISHAI_DATABASE_PASSWORD"), "NAVISHAI_DATABASE_PASSWORD"
    end
    postgres = services.fetch("postgres")
    assert_equal "navishai_setup", postgres.fetch("environment").fetch("POSTGRES_USER")
    assert_includes postgres.fetch("environment").fetch("POSTGRES_PASSWORD"), "NAVISHAI_POSTGRES_PASSWORD"
    assert_includes postgres.fetch("volumes"), "./db/initialize_runtime_role.sh:/docker-entrypoint-initdb.d/10-navishai-runtime.sh:ro"
    assert_not_includes File.read(Rails.root.join("Dockerfile")), "docker-entrypoint"
  end

  test "all production database configurations share the restricted default username" do
    assert_equal %w[primary cache queue cable], ActiveRecord::Base.configurations.configs_for(env_name: "production").map(&:name)
    ActiveRecord::Base.configurations.configs_for(env_name: "production").each do |config|
      assert_equal "navishai", config.configuration_hash.fetch(:username)
    end
  end

  test "initialization refuses equal credentials without running SQL or printing either value" do
    sentinel = "synthetic-same-password-not-a-credential"
    output, status = Open3.capture2e({ "NAVISHAI_DATABASE_PASSWORD" => sentinel, "POSTGRES_PASSWORD" => sentinel },
      "sh", Rails.root.join("db/initialize_runtime_role.sh").to_s)
    assert_not status.success?
    assert_includes output, "Preparation and runtime passwords must differ."
    assert_not_includes output, sentinel
  end

  test "grant task refuses development and test before changing any database" do
    output, status = Open3.capture2e({ "RAILS_ENV" => "test" }, Rails.root.join("bin/rails").to_s, "db:grant_runtime")
    assert_not status.success?
    assert_includes output, "Runtime grants require RAILS_ENV=production."
  end
end
