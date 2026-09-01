require "fileutils"
require "json"
require "net/http"
require "pathname"
require "securerandom"

module Navishai
  class DevelopmentEnvironment
    Plan = Data.define(
      :root, :runner_environment, :runner_command, :rails_environment, :rails_command,
      :runner_health_uri
    )

    SECRET_BYTES = 32
    RUNNER_READY_TIMEOUT = 60
    DEFAULT_ROOT = Pathname(__dir__).join("..", "..").expand_path

    def initialize(root: DEFAULT_ROOT, environment: ENV)
      @root = Pathname(root).expand_path
      @environment = environment
    end

    def prepare(rails_arguments: [])
      shared_secret = configured_secret("NAVISHAI_RUNNER_SHARED_SECRET", "shared-secret")
      vault_secret = configured_secret("NAVISHAI_RUNNER_PROVIDER_VAULT_SECRET", "provider-vault-secret")
      raise "development runner secrets must be different" if shared_secret == vault_secret

      bind_address = @environment.fetch("NAVISHAI_RUNNER_BIND_ADDRESS", "127.0.0.1:8081")
      runner_address = @environment.fetch("NAVISHAI_RUNNER_ADDRESS", "http://#{bind_address}")
      runner_uri = URI.parse(runner_address)
      unless runner_uri.scheme == "http" && [ "127.0.0.1", "::1", "localhost" ].include?(runner_uri.host) &&
          [ "", "/" ].include?(runner_uri.path) && runner_uri.query.nil? && runner_uri.fragment.nil?
        raise "development runner address must be a loopback HTTP origin"
      end

      state_root = @root.join("storage", "development-runner")
      work_root = @root.join("tmp", "development-runner", "runs")
      config_path = @root.join("tmp", "development-runner", "execution.json")
      FileUtils.mkdir_p(state_root, mode: 0o700)
      FileUtils.mkdir_p(work_root, mode: 0o700)
      write_execution_config(config_path, work_root)

      runner_environment = {
        "NAVISHAI_RUNNER_BIND_ADDRESS" => bind_address,
        "NAVISHAI_RUNNER_SHARED_SECRET" => shared_secret,
        "NAVISHAI_RUNNER_PROVIDER_VAULT_SECRET" => vault_secret,
        "NAVISHAI_RUNNER_STATE_PATH" => state_root.join("admissions.json").to_s,
        "NAVISHAI_RUNNER_EXECUTION_CONFIG" => config_path.to_s,
        "NAVISHAI_CONTROL_PLANE_ADDRESS" => @environment.fetch(
          "NAVISHAI_CONTROL_PLANE_ADDRESS", "http://127.0.0.1:#{@environment.fetch("PORT", "3000")}"
        )
      }
      rails_environment = {
        "NAVISHAI_RUNNER_ADDRESS" => runner_address,
        "NAVISHAI_RUNNER_SHARED_SECRET" => shared_secret
      }

      Plan.new(
        root: @root.to_s,
        runner_environment:,
        runner_command: [ "go", "run", "./runner/cmd/navishai-runner" ],
        rails_environment:,
        rails_command: [ "./bin/rails", "server", *rails_arguments ],
        runner_health_uri: URI.join(runner_address, "/readyz")
      )
    rescue URI::InvalidURIError
      raise "development runner address is invalid"
    end

    def wait_until_runner_ready(plan, runner_pid:, timeout: RUNNER_READY_TIMEOUT)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        reaped = Process.waitpid(runner_pid, Process::WNOHANG)
        return false if reaped

        begin
          response = Net::HTTP.start(
            plan.runner_health_uri.host,
            plan.runner_health_uri.port,
            open_timeout: 1,
            read_timeout: 1
          ) { |http| http.get(plan.runner_health_uri.request_uri) }
          return true if response.code == "200"
        rescue IOError, SystemCallError, Timeout::Error
          # The runner may still be compiling or binding its listener.
        end
        return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.1
      end
    end

    private
      def configured_secret(environment_key, filename)
        configured = @environment[environment_key].to_s
        unless configured.empty?
          raise "#{environment_key} must contain at least #{SECRET_BYTES} bytes" if configured.bytesize < SECRET_BYTES
          return configured
        end

        path = @root.join("storage", "development-runner", filename)
        FileUtils.mkdir_p(path.dirname, mode: 0o700)
        if path.exist?
          secret = path.binread.strip
          raise "#{path} must contain at least #{SECRET_BYTES} bytes" if secret.bytesize < SECRET_BYTES
          File.chmod(0o600, path)
          return secret
        end

        secret = SecureRandom.hex(SECRET_BYTES)
        write_private_file(path, "#{secret}\n")
        secret
      end

      def write_execution_config(path, work_root)
        template = JSON.parse(@root.join("ops", "runner", "execution.example.json").binread)
        template.fetch("supervisor")["allowed_working_roots"] = [ work_root.to_s ]
        template["work_root"] = work_root.to_s
        FileUtils.mkdir_p(path.dirname, mode: 0o700)
        write_private_file(path, JSON.pretty_generate(template) + "\n")
      end

      def write_private_file(path, contents)
        temporary = Pathname("#{path}.#{Process.pid}.tmp")
        File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          file.write(contents)
          file.flush
          file.fsync
        end
        File.rename(temporary, path)
        File.chmod(0o600, path)
      ensure
        FileUtils.rm_f(temporary) if temporary
      end
  end
end
