require "test_helper"
require "tmpdir"
require "navishai/development_environment"

module Navishai
  class DevelopmentEnvironmentTest < ActiveSupport::TestCase
    test "prepares persistent private secrets and a writable fail-closed runner policy" do
      Dir.mktmpdir do |directory|
        root = Pathname(directory)
        copy_policy_template(root)
        environment = DevelopmentEnvironment.new(root:, environment: {})

        first = environment.prepare
        second = environment.prepare

        assert_equal first.runner_environment.fetch("NAVISHAI_RUNNER_SHARED_SECRET"),
          second.runner_environment.fetch("NAVISHAI_RUNNER_SHARED_SECRET")
        assert_equal first.runner_environment.fetch("NAVISHAI_RUNNER_PROVIDER_VAULT_SECRET"),
          second.runner_environment.fetch("NAVISHAI_RUNNER_PROVIDER_VAULT_SECRET")
        refute_equal first.runner_environment.fetch("NAVISHAI_RUNNER_SHARED_SECRET"),
          first.runner_environment.fetch("NAVISHAI_RUNNER_PROVIDER_VAULT_SECRET")
        assert_equal first.runner_environment.fetch("NAVISHAI_RUNNER_SHARED_SECRET"),
          first.rails_environment.fetch("NAVISHAI_RUNNER_SHARED_SECRET")

        %w[shared-secret provider-vault-secret].each do |filename|
          path = root.join("storage", "development-runner", filename)
          assert_equal 0o600, path.stat.mode & 0o777
        end

        config = JSON.parse(Pathname(first.runner_environment.fetch("NAVISHAI_RUNNER_EXECUTION_CONFIG")).read)
        expected_work_root = root.join("tmp", "development-runner", "runs").to_s
        assert_equal expected_work_root, config.fetch("work_root")
        assert_equal [ expected_work_root ], config.dig("supervisor", "allowed_working_roots")
        assert config.fetch("adapters").except("scripted").values.none? { |adapter| adapter.fetch("enabled") }
      end
    end

    test "builds matching runner and Rails process plans without exposing vault credentials to Rails" do
      Dir.mktmpdir do |directory|
        root = Pathname(directory)
        copy_policy_template(root)
        plan = DevelopmentEnvironment.new(root:, environment: { "PORT" => "3100" }).prepare(
          rails_arguments: [ "-b", "127.0.0.1" ]
        )

        assert_equal [ "go", "run", "./runner/cmd/navishai-runner" ], plan.runner_command
        assert_equal [ "./bin/rails", "server", "-b", "127.0.0.1" ], plan.rails_command
        assert_equal "http://127.0.0.1:8081", plan.rails_environment.fetch("NAVISHAI_RUNNER_ADDRESS")
        assert_equal "http://127.0.0.1:3100", plan.runner_environment.fetch("NAVISHAI_CONTROL_PLANE_ADDRESS")
        refute plan.rails_environment.key?("NAVISHAI_RUNNER_PROVIDER_VAULT_SECRET")
        assert_equal "/readyz", plan.runner_health_uri.path
      end
    end

    test "refuses to replace an unreadable existing vault secret" do
      Dir.mktmpdir do |directory|
        root = Pathname(directory)
        copy_policy_template(root)
        secret_root = root.join("storage", "development-runner")
        FileUtils.mkdir_p(secret_root)
        secret_root.join("provider-vault-secret").write("short\n")

        error = assert_raises(RuntimeError) { DevelopmentEnvironment.new(root:, environment: {}).prepare }
        assert_includes error.message, "provider-vault-secret"
      end
    end

    private
      def copy_policy_template(root)
        destination = root.join("ops", "runner")
        FileUtils.mkdir_p(destination)
        FileUtils.cp(Rails.root.join("ops", "runner", "execution.example.json"), destination)
      end
  end
end
