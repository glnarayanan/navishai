require "test_helper"
require "open3"
require "tmpdir"
require "fileutils"
require_relative "../test_helpers/candidate_https_server"

class BootstrapTest < ActiveSupport::TestCase
  def test_unsupported_host_stops_before_any_host_change
    Dir.mktmpdir do |root|
      bundle = File.join(root, "candidate.tar")
      release = File.join(root, "os-release")
      File.write(bundle, "candidate")
      File.write(release, "ID=alpine\nVERSION_ID=3.20\n")

      _stdout, stderr, status = run_bootstrap(root, bundle, "NAVISHAI_OS_RELEASE" => release)

      assert_not status.success?
      assert_includes stderr, "supported hosts"
      refute_path_exists File.join(root, "etc/apt")
    end
  end

  def test_unsupported_host_stops_before_downloading_a_candidate
    Dir.mktmpdir do |root|
      release = File.join(root, "os-release")
      File.write(release, "ID=alpine\nVERSION_ID=3.20\n")
      checksum, destination = trusted_candidate(root, "candidate")

      _stdout, stderr, status = run_bootstrap(root, "https://releases.example/candidate.tar",
        "NAVISHAI_OS_RELEASE" => release, "NAVISHAI_CANDIDATE_SHA256_FILE" => checksum, "NAVISHAI_CANDIDATE_DESTINATION" => destination)

      assert_not status.success?
      assert_includes stderr, "supported hosts"
      refute_path_exists File.join(root, "commands.log")
      refute File.exist?(destination)
      refute File.exist?("#{destination}.part")
    end
  end

  def test_missing_prerequisites_decline_without_mutation
    Dir.mktmpdir do |root|
      bundle = File.join(root, "candidate.tar")
      File.write(bundle, "candidate")

      _stdout, stderr, status = run_bootstrap(root, bundle)

      assert_not status.success?
      assert_includes stderr, "NAVISHAI_BOOTSTRAP_ACCEPT=yes"
      refute_path_exists File.join(root, "etc/apt")
    end
  end

  def test_preinstalled_docker_and_compose_forward_to_setup
    Dir.mktmpdir do |root|
      bundle = File.join(root, "candidate.tar")
      File.write(bundle, "candidate")

      _stdout, stderr, status = run_bootstrap(root, bundle, "FAKE_DOCKER" => "present")

      assert status.success?, stderr
      assert_includes File.read(File.join(root, "commands.log")), "setup #{bundle}"
    end
  end

  def test_https_candidate_download_verifies_before_setup
    Dir.mktmpdir do |root|
      body = "verified candidate"
      checksum = File.join(root, "candidate.sha256")
      File.write(checksum, Digest::SHA256.hexdigest(body))
      FileUtils.chmod(0o600, checksum)
      destination = File.join(root, "downloaded.tar")

      _stdout, stderr, status = run_bootstrap(root, "https://releases.example/candidate.tar",
        "FAKE_DOCKER" => "present", "NAVISHAI_CANDIDATE_SHA256_FILE" => checksum,
        "NAVISHAI_CANDIDATE_DESTINATION" => destination, "FAKE_CURL_BODY" => body)

      assert status.success?, stderr
      assert_equal body, File.read(destination)
      assert_includes File.read(File.join(root, "commands.log")), "setup #{destination}"
    end
  end

  def test_https_candidate_checksum_failure_does_not_execute_setup
    Dir.mktmpdir do |root|
      checksum = File.join(root, "candidate.sha256")
      File.write(checksum, "#{'0' * 64}\n")
      FileUtils.chmod(0o600, checksum)
      destination = File.join(root, "downloaded.tar")

      _stdout, stderr, status = run_bootstrap(root, "https://releases.example/candidate.tar",
        "FAKE_DOCKER" => "present", "NAVISHAI_CANDIDATE_SHA256_FILE" => checksum,
        "NAVISHAI_CANDIDATE_DESTINATION" => destination, "FAKE_CURL_BODY" => "corrupt")

      assert_not status.success?
      assert_includes stderr, "checksum did not match"
      refute File.exist?(destination)
      refute File.read(File.join(root, "commands.log")).include?("setup ")
    end
  end

  def test_candidate_download_rejects_non_https_before_docker_or_setup
    Dir.mktmpdir do |root|
      _stdout, stderr, status = run_bootstrap(root, "http://releases.example/candidate.tar", "FAKE_DOCKER" => "present")

      assert_not status.success?
      assert_includes stderr, "must use HTTPS"
      refute_path_exists File.join(root, "commands.log")
    end
  end

  def test_https_candidate_rejects_malformed_checksum_before_download
    Dir.mktmpdir do |root|
      checksum = File.join(root, "candidate.sha256")
      File.write(checksum, "not-a-checksum\n")
      FileUtils.chmod(0o600, checksum)

      _stdout, stderr, status = run_bootstrap(root, "https://releases.example/candidate.tar",
        "FAKE_DOCKER" => "present", "NAVISHAI_CANDIDATE_SHA256_FILE" => checksum)

      assert_not status.success?
      assert_includes stderr, "must be a SHA-256"
      refute_path_exists File.join(root, "commands.log")
    end
  end

  def test_interrupted_https_transfer_resumes_with_a_byte_range_on_rerun
    Dir.mktmpdir do |root|
      body = SecureRandom.random_bytes(100_000)
      server = CandidateHttpsServer.new(root, body:, cut_first_full_after: 40_000)
      checksum, destination = trusted_candidate(root, body)

      _stdout, stderr, first = run_bootstrap(root, server.url, real_curl: true, **https_environment(server, checksum, destination))

      assert_not first.success?
      assert_includes stderr, "rerun bootstrap to resume"
      assert_equal 40_000, File.size("#{destination}.part")
      refute File.exist?(destination)
      refute_path_exists File.join(root, "commands.log")

      _stdout, stderr, second = run_bootstrap(root, server.url, real_curl: true, **https_environment(server, checksum, destination))

      assert second.success?, stderr
      assert_equal body, File.binread(destination)
      refute File.exist?("#{destination}.part")
      assert_equal [ nil, "bytes=40000-" ], server.requests.map { |request| request[:range] }
      assert_includes File.read(File.join(root, "commands.log")), "setup #{destination}"
    ensure
      server&.stop
    end
  end

  def test_corrupt_partial_download_is_removed_after_checksum_rejection_and_rerun_downloads_again
    Dir.mktmpdir do |root|
      body = SecureRandom.random_bytes(100_000)
      server = CandidateHttpsServer.new(root, body:)
      checksum, destination = trusted_candidate(root, body)
      File.binwrite("#{destination}.part", SecureRandom.random_bytes(40_000))

      _stdout, stderr, first = run_bootstrap(root, server.url, real_curl: true, **https_environment(server, checksum, destination))

      assert_not first.success?
      assert_includes stderr, "checksum did not match"
      refute File.exist?("#{destination}.part")
      refute File.exist?(destination)
      refute_path_exists File.join(root, "commands.log")
      assert_equal [ "bytes=40000-" ], server.requests.map { |request| request[:range] }

      _stdout, stderr, second = run_bootstrap(root, server.url, real_curl: true, **https_environment(server, checksum, destination))

      assert second.success?, stderr
      assert_equal body, File.binread(destination)
      assert_equal [ "bytes=40000-", nil ], server.requests.map { |request| request[:range] }
      assert_includes File.read(File.join(root, "commands.log")), "setup #{destination}"
    ensure
      server&.stop
    end
  end

  def test_stale_full_size_partial_is_rejected_by_checksum_not_accepted_from_a_416_reply
    Dir.mktmpdir do |root|
      body = SecureRandom.random_bytes(100_000)
      server = CandidateHttpsServer.new(root, body:)
      checksum, destination = trusted_candidate(root, body)
      File.binwrite("#{destination}.part", SecureRandom.random_bytes(100_000))

      _stdout, stderr, status = run_bootstrap(root, server.url, real_curl: true, **https_environment(server, checksum, destination))

      assert_not status.success?
      assert_includes stderr, "checksum did not match"
      refute File.exist?("#{destination}.part")
      refute File.exist?(destination)
      refute_path_exists File.join(root, "commands.log")
    ensure
      server&.stop
    end
  end

  def test_server_without_range_support_restarts_the_transfer_instead_of_failing_forever
    Dir.mktmpdir do |root|
      body = SecureRandom.random_bytes(100_000)
      server = CandidateHttpsServer.new(root, body:, ranges: false)
      checksum, destination = trusted_candidate(root, body)
      File.binwrite("#{destination}.part", body.byteslice(0, 40_000))

      _stdout, stderr, status = run_bootstrap(root, server.url, real_curl: true, **https_environment(server, checksum, destination))

      assert status.success?, stderr
      assert_equal body, File.binread(destination)
      assert_equal [ "bytes=40000-", nil ], server.requests.map { |request| request[:range] }
      assert_includes File.read(File.join(root, "commands.log")), "setup #{destination}"
    ensure
      server&.stop
    end
  end

  def test_https_redirect_to_http_is_refused_before_setup
    Dir.mktmpdir do |root|
      body = SecureRandom.random_bytes(1_000)
      server = CandidateHttpsServer.new(root, body:, redirect: "http://127.0.0.1:9/candidate.tar")
      checksum, destination = trusted_candidate(root, body)

      _stdout, stderr, status = run_bootstrap(root, server.url("/redirect"), real_curl: true, **https_environment(server, checksum, destination))

      assert_not status.success?
      assert_includes stderr, "candidate download failed"
      assert_equal [ "/redirect" ], server.requests.map { |request| request[:path] }
      refute File.exist?(destination)
      refute_path_exists File.join(root, "commands.log")
    ensure
      server&.stop
    end
  end

  def test_https_redirect_to_https_is_followed_and_verified
    Dir.mktmpdir do |root|
      body = SecureRandom.random_bytes(1_000)
      server = CandidateHttpsServer.new(root, body:, redirect: "/candidate.tar")
      checksum, destination = trusted_candidate(root, body)

      _stdout, stderr, status = run_bootstrap(root, server.url("/redirect"), real_curl: true, **https_environment(server, checksum, destination))

      assert status.success?, stderr
      assert_equal body, File.binread(destination)
      assert_equal [ "/redirect", "/candidate.tar" ], server.requests.map { |request| request[:path] }
      assert_includes File.read(File.join(root, "commands.log")), "setup #{destination}"
    ensure
      server&.stop
    end
  end

  def test_already_verified_candidate_is_reused_without_a_download
    Dir.mktmpdir do |root|
      body = SecureRandom.random_bytes(1_000)
      server = CandidateHttpsServer.new(root, body:)
      checksum, destination = trusted_candidate(root, body)
      File.binwrite(destination, body)

      stdout, stderr, status = run_bootstrap(root, server.url, real_curl: true, **https_environment(server, checksum, destination))

      assert status.success?, stderr
      assert_includes stdout, "Reusing the verified candidate"
      assert_empty server.requests
      assert_includes File.read(File.join(root, "commands.log")), "setup #{destination}"
    ensure
      server&.stop
    end
  end

  def test_https_candidate_requires_curl_before_any_download_state
    Dir.mktmpdir do |root|
      checksum, destination = trusted_candidate(root, "candidate")
      tools = File.join(root, "tools")
      FileUtils.mkdir_p(tools)
      %w[bash sh tr stat sha256sum cut id mkdir rm mv dirname cat grep].each do |tool|
        path = ENV.fetch("PATH").split(File::PATH_SEPARATOR).map { |directory| File.join(directory, tool) }.find { |candidate| File.executable?(candidate) }
        File.symlink(path, File.join(tools, tool)) if path
      end

      _stdout, stderr, status = run_bootstrap(root, "https://releases.example/candidate.tar", real_curl: true,
        "FAKE_DOCKER" => "present", "NAVISHAI_CANDIDATE_SHA256_FILE" => checksum,
        "NAVISHAI_CANDIDATE_DESTINATION" => File.join(root, "missing-parent/candidate.tar"), "PATH" => "#{File.join(root, 'bin')}:#{tools}")

      assert_not status.success?
      assert_includes stderr, "curl is required"
      refute_path_exists File.join(root, "missing-parent")
      refute_path_exists File.join(root, "commands.log")
    end
  end

  def test_clean_install_orders_prerequisites_docker_readiness_and_setup
    Dir.mktmpdir do |root|
      bundle = File.join(root, "candidate.tar")
      File.write(bundle, "candidate")

      _stdout, stderr, status = run_bootstrap(root, bundle, "NAVISHAI_BOOTSTRAP_ACCEPT" => "yes")

      assert status.success?, stderr
      commands = File.readlines(File.join(root, "commands.log"), chomp: true)
      prerequisite_install = commands.index("apt install -y --no-remove ca-certificates curl")
      docker_install = commands.index("apt install -y --no-remove ca-certificates curl docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin")
      final_compose_check = commands.rindex("docker compose version")

      assert_operator prerequisite_install, :<, commands.index("curl")
      assert_operator docker_install, :<, commands.index("systemctl")
      assert_operator commands.index("docker info"), :<, final_compose_check
      assert_operator final_compose_check, :<, commands.index("setup #{bundle}")
    end
  end

  def test_docker_info_failure_stops_before_compose_check_or_setup
    Dir.mktmpdir do |root|
      bundle = File.join(root, "candidate.tar")
      File.write(bundle, "candidate")

      _stdout, stderr, status = run_bootstrap(root, bundle,
        "NAVISHAI_BOOTSTRAP_ACCEPT" => "yes", "FAKE_DOCKER_INFO_FAIL" => "1")

      assert_not status.success?
      assert_includes stderr, "Docker daemon is not ready"
      commands = command_lines(root)
      assert_includes commands, "docker info"
      assert_equal 1, commands.count("docker compose version")
      assert_setup_not_called(commands)
    end
  end

  def test_compose_version_failure_stops_before_setup
    Dir.mktmpdir do |root|
      bundle = File.join(root, "candidate.tar")
      File.write(bundle, "candidate")

      _stdout, stderr, status = run_bootstrap(root, bundle,
        "NAVISHAI_BOOTSTRAP_ACCEPT" => "yes", "FAKE_DOCKER_COMPOSE_FAIL" => "1")

      assert_not status.success?
      assert_includes stderr, "Docker Compose installation failed"
      commands = command_lines(root)
      assert_includes commands, "docker info"
      assert_includes commands, "docker compose version"
      assert_setup_not_called(commands)
    end
  end

  def test_prerequisite_install_failure_stops_before_key_fetch_or_setup
    Dir.mktmpdir do |root|
      bundle = File.join(root, "candidate.tar")
      File.write(bundle, "candidate")

      _stdout, _stderr, status = run_bootstrap(root, bundle,
        "NAVISHAI_BOOTSTRAP_ACCEPT" => "yes", "FAKE_APT_FAIL_STAGE" => "prerequisites")

      assert_not status.success?
      commands = command_lines(root)
      assert_includes commands, "apt install -y --no-remove ca-certificates curl"
      refute_includes commands, "curl"
      refute_includes commands, "systemctl"
      assert_setup_not_called(commands)
    end
  end

  def test_existing_docker_source_is_preserved_when_compose_is_missing
    Dir.mktmpdir do |root|
      bundle = File.join(root, "candidate.tar")
      key = File.join(root, "etc/apt/keyrings/docker.asc")
      FileUtils.mkdir_p(File.dirname(key))
      File.write(bundle, "candidate")
      File.write(key, "existing-key")

      _stdout, stderr, status = run_bootstrap(root, bundle, "FAKE_DOCKER" => "docker-only", "NAVISHAI_BOOTSTRAP_ACCEPT" => "yes")

      assert_not status.success?
      assert_includes stderr, "existing Docker apt source or key"
      assert_equal "existing-key", File.read(key)
      assert_equal [ "docker compose version" ], command_lines(root)
    end
  end

  def test_existing_docker_source_file_is_preserved_when_compose_is_missing
    Dir.mktmpdir do |root|
      bundle = File.join(root, "candidate.tar")
      source = File.join(root, "etc/apt/sources.list.d/docker.list")
      FileUtils.mkdir_p(File.dirname(source))
      File.write(bundle, "candidate")
      File.write(source, "existing-source")

      _stdout, stderr, status = run_bootstrap(root, bundle, "FAKE_DOCKER" => "docker-only", "NAVISHAI_BOOTSTRAP_ACCEPT" => "yes")

      assert_not status.success?
      assert_includes stderr, "existing Docker apt source or key"
      assert_equal "existing-source", File.read(source)
      assert_equal [ "docker compose version" ], command_lines(root)
    end
  end

  def test_dangling_docker_key_symlink_stops_before_package_commands
    Dir.mktmpdir do |root|
      bundle = File.join(root, "candidate.tar")
      key = File.join(root, "etc/apt/keyrings/docker.asc")
      FileUtils.mkdir_p(File.dirname(key))
      File.write(bundle, "candidate")
      File.symlink("missing-key", key)

      _stdout, stderr, status = run_bootstrap(root, bundle, "NAVISHAI_BOOTSTRAP_ACCEPT" => "yes")

      assert_not status.success?
      assert_includes stderr, "existing Docker apt source or key"
      assert File.symlink?(key)
      assert_equal [ "docker compose version" ], command_lines(root)
    end
  end

  def test_dangling_docker_source_symlink_stops_before_package_commands
    Dir.mktmpdir do |root|
      bundle = File.join(root, "candidate.tar")
      source = File.join(root, "etc/apt/sources.list.d/docker.list")
      FileUtils.mkdir_p(File.dirname(source))
      File.write(bundle, "candidate")
      File.symlink("missing-source", source)

      _stdout, stderr, status = run_bootstrap(root, bundle, "NAVISHAI_BOOTSTRAP_ACCEPT" => "yes")

      assert_not status.success?
      assert_includes stderr, "existing Docker apt source or key"
      assert File.symlink?(source)
      assert_equal [ "docker compose version" ], command_lines(root)
    end
  end

  private

  def trusted_candidate(root, body)
    checksum = File.join(root, "candidate.sha256")
    File.write(checksum, "#{Digest::SHA256.hexdigest(body)}\n")
    FileUtils.chmod(0o600, checksum)
    FileUtils.mkdir_p(File.join(root, "downloads"))
    [ checksum, File.join(root, "downloads/candidate.tar") ]
  end

  def https_environment(server, checksum, destination)
    server.curl_environment.merge("FAKE_DOCKER" => "present", "NAVISHAI_CANDIDATE_SHA256_FILE" => checksum,
      "NAVISHAI_CANDIDATE_DESTINATION" => destination)
  end

  def command_lines(root)
    File.readlines(File.join(root, "commands.log"), chomp: true)
  end

  def assert_setup_not_called(commands)
    refute commands.any? { |command| command.start_with?("setup ") }, commands.join("\n")
  end

  def run_bootstrap(root, bundle, real_curl: false, **extra)
    bin = File.join(root, "bin")
    installer = File.join(root, "installer")
    FileUtils.mkdir_p(bin)
    FileUtils.mkdir_p(installer)
    FileUtils.cp(Rails.root.join("ops/installer/bootstrap"), File.join(installer, "bootstrap"))
    File.write(File.join(installer, "navishai"), "#!/bin/sh\necho \"$*\" >>\"$BOOTSTRAP_LOG\"\n")
    FileUtils.chmod(0o755, [ File.join(installer, "bootstrap"), File.join(installer, "navishai") ])
    File.write(File.join(bin, "uname"), "#!/bin/sh\necho x86_64\n")
    File.write(File.join(bin, "docker"), "#!/bin/sh\nstate=\"$NAVISHAI_BOOTSTRAP_ROOT/docker-installed\"\nif [ \"$1\" = info ]; then echo \"docker info\" >>\"$BOOTSTRAP_LOG\"; [ \"${FAKE_DOCKER_INFO_FAIL:-0}\" = 1 ] && exit 1; exit 0; fi\nif [ \"$1\" = compose ]; then echo \"docker compose version\" >>\"$BOOTSTRAP_LOG\"; [ \"${FAKE_DOCKER_COMPOSE_FAIL:-0}\" = 1 ] && exit 1; [ \"${FAKE_DOCKER:-missing}\" = docker-only ] && exit 1; [ -f \"$state\" ] || [ \"${FAKE_DOCKER:-missing}\" = present ] || exit 1; exit 0; fi\n[ \"${FAKE_DOCKER:-missing}\" = missing ] && [ ! -f \"$state\" ] && exit 1\nexit 0\n")
    File.write(File.join(bin, "apt"), "#!/bin/sh\necho \"apt $*\" >>\"$BOOTSTRAP_LOG\"\ncase \" $* \" in *\" ca-certificates curl \"*) [ \"${FAKE_APT_FAIL_STAGE:-}\" = prerequisites ] && exit 1;; esac\n[ \"${FAKE_APT_FAIL_STAGE:-}\" = update ] && [ \"$1\" = update ] && exit 1\ncase \" $* \" in *\" docker-ce \"*) [ \"${FAKE_APT_FAIL_STAGE:-}\" = docker ] && exit 1; : >\"$NAVISHAI_BOOTSTRAP_ROOT/docker-installed\";; esac\nexit 0\n")
    File.write(File.join(bin, "curl"), "#!/bin/sh\necho curl >>\"$BOOTSTRAP_LOG\"\nwhile [ \"$#\" -gt 0 ]; do case \"$1\" in -o|--output) printf '%s' \"${FAKE_CURL_BODY:-key}\" >\"$2\"; break;; esac; shift; done\n") unless real_curl
    File.write(File.join(bin, "dpkg-query"), "#!/bin/sh\nexit 1\n")
    File.write(File.join(bin, "systemctl"), "#!/bin/sh\necho systemctl >>\"$BOOTSTRAP_LOG\"\n")
    FileUtils.chmod(0o755, File.join(bin, "uname"))
    FileUtils.chmod(0o755, File.join(bin, "docker"))
    FileUtils.chmod(0o755, [ File.join(bin, "apt"), File.join(bin, "dpkg-query"), File.join(bin, "systemctl") ])
    FileUtils.chmod(0o755, File.join(bin, "curl")) unless real_curl
    release = File.join(root, "os-release")
    File.write(release, "ID=debian\nVERSION_ID=12\nVERSION_CODENAME=bookworm\n") unless extra.key?("NAVISHAI_OS_RELEASE")
    environment = {
      "PATH" => "#{bin}:#{ENV.fetch("PATH")}",
      "NAVISHAI_BOOTSTRAP_ROOT" => root,
      "NAVISHAI_BOOTSTRAP_TEST_ROOT" => "1",
      "NAVISHAI_APT_GET" => File.join(bin, "apt"),
      "BOOTSTRAP_LOG" => File.join(root, "commands.log")
    }.merge({ "NAVISHAI_OS_RELEASE" => release }.merge(extra))
    Open3.capture3(environment, File.join(installer, "bootstrap"), bundle)
  end
end
