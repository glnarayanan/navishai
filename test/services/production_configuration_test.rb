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
      %w[EVALUATION SCENARIO CORPUS MATCHING IMPACT TRACE_DISCOVERY].each do |purpose|
        key = "NAVISHAI_#{purpose}_ENDPOINTS"
        assert_equal "${#{key}:-[]}", environment.fetch(key)
      end
    end
    postgres = services.fetch("postgres")
    assert_equal "navishai_setup", postgres.fetch("environment").fetch("POSTGRES_USER")
    assert_includes postgres.fetch("environment").fetch("POSTGRES_PASSWORD"), "NAVISHAI_POSTGRES_PASSWORD"
    assert_includes postgres.fetch("volumes"), "./db/initialize_runtime_role.sh:/docker-entrypoint-initdb.d/10-navishai-runtime.sh:ro"
    assert_not_includes File.read(Rails.root.join("Dockerfile")), "docker-entrypoint"
  end

  test "Compose prepares as the owner on the control network before web and jobs start" do
    services = YAML.safe_load_file(Rails.root.join("compose.yaml"), aliases: true).fetch("services")
    prepare = services.fetch("prepare")
    assert_equal %w[bin/rails db:prepare db:grant_runtime], prepare.fetch("command")
    assert_equal "no", prepare.fetch("restart")
    assert_equal %w[control], prepare.fetch("networks")
    assert_not prepare.key?("ports")
    assert_equal %w[ALL], prepare.fetch("cap_drop")
    assert_equal %w[no-new-privileges:true], prepare.fetch("security_opt")
    assert_equal({ "postgres" => { "condition" => "service_healthy" } }, prepare.fetch("depends_on"))
    environment = prepare.fetch("environment")
    assert_equal "navishai_setup", environment.fetch("NAVISHAI_DATABASE_USERNAME")
    assert_includes environment.fetch("NAVISHAI_DATABASE_PASSWORD"), "NAVISHAI_POSTGRES_PASSWORD"
    assert_empty environment.keys.grep(/ENDPOINTS|OIDC|SMTP|BOOTSTRAP/)
    %w[web jobs].each do |name|
      dependencies = services.fetch(name).fetch("depends_on")
      assert_equal "service_healthy", dependencies.dig("postgres", "condition")
      assert_equal "service_completed_successfully", dependencies.dig("prepare", "condition")
      assert_not_includes services.fetch(name).fetch("command"), "db:prepare"
    end
    vps = YAML.safe_load_file(Rails.root.join("ops/vps/compose.yaml"), aliases: true).fetch("services")
    assert_equal %w[vps-cli-disabled], vps.fetch("prepare").fetch("profiles")
  end

  test "Compose web declares its networks directly rather than only through the merge anchor" do
    pairs = ->(node) { node.children.each_slice(2).to_h { |key, value| [ key.value, value ] } }
    web = pairs.(pairs.(Psych.parse_file(Rails.root.join("compose.yaml")).root).fetch("services")).fetch("web")
    assert_equal %w[control edge], pairs.(web).fetch("networks").children.map(&:value)
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
