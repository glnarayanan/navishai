require "test_helper"
require "open3"
require "tmpdir"
require "fileutils"

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

  def command_lines(root)
    File.readlines(File.join(root, "commands.log"), chomp: true)
  end

  def assert_setup_not_called(commands)
    refute commands.any? { |command| command.start_with?("setup ") }, commands.join("\n")
  end

  def run_bootstrap(root, bundle, extra = {})
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
    File.write(File.join(bin, "curl"), "#!/bin/sh\necho curl >>\"$BOOTSTRAP_LOG\"\nwhile [ \"$#\" -gt 0 ]; do [ \"$1\" = -o ] && { printf key >\"$2\"; break; }; shift; done\n")
    File.write(File.join(bin, "dpkg-query"), "#!/bin/sh\nexit 1\n")
    File.write(File.join(bin, "systemctl"), "#!/bin/sh\necho systemctl >>\"$BOOTSTRAP_LOG\"\n")
    FileUtils.chmod(0o755, File.join(bin, "uname"))
    FileUtils.chmod(0o755, File.join(bin, "docker"))
    FileUtils.chmod(0o755, [ File.join(bin, "apt"), File.join(bin, "curl"), File.join(bin, "dpkg-query"), File.join(bin, "systemctl") ])
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
