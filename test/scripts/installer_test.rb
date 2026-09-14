require "test_helper"
require "open3"
require "tmpdir"
require "fileutils"
require "shellwords"
require "json"

class InstallerTest < ActiveSupport::TestCase
  def test_installer_host_allowlists_include_supported_ubuntu_releases
    [ Rails.root.join("ops/installer/bootstrap"), Rails.root.join("ops/installer/navishai") ].each do |path|
      assert_includes File.read(path), "VERSION_ID == 24.04 || $VERSION_ID == 26.04"
    end
  end

  def test_second_setup_rejects_held_lock_before_docker
    Dir.mktmpdir do |root|
      lock = "#{root}/var/lib/navishai/install.lock"
      FileUtils.mkdir_p(File.dirname(lock))
      holder = Process.spawn("flock", "-n", lock, "sleep", "10")
      sleep 0.1
      stdout, stderr, status = run_installer(root, "setup", "missing.tar")

      assert_not status.success?
      assert_empty stdout
      assert_includes stderr, "another mutating operation is running"
    ensure
      Process.kill("TERM", holder) if holder
      Process.wait(holder) if holder
    end
  end

  def test_setup_acquires_lock_after_a_killed_holder_exits
    Dir.mktmpdir do |root|
      lock = "#{root}/var/lib/navishai/install.lock"
      ready = "#{root}/holder-ready"
      FileUtils.mkdir_p(File.dirname(lock))
      holder = Process.spawn("flock", "-n", lock, "sh", "-c", "touch \"$0\"; sleep 10", ready, pgroup: true)
      sleep 0.01 until File.exist?(ready)
      Process.kill("KILL", -holder)
      Process.wait(holder)
      holder = nil

      _stdout, stderr, status = run_installer(root, "setup", "missing.tar")

      assert_not status.success?
      assert_includes stderr, "bundle not found"
      refute_includes stderr, "another mutating operation is running"
    ensure
      Process.kill("TERM", holder) if holder
      Process.wait(holder) if holder
    end
  end

  {
    "backup" => [ "archive" ],
    "restore" => [ "archive", "--confirm-destroy" ],
    "upgrade" => [ "backup", "target.tar", "--confirm-apply" ]
  }.each do |command, arguments|
    define_method("test_#{command}_rejects_a_held_mutating_operation_lock_before_docker") do
      Dir.mktmpdir do |root|
        lock = "#{root}/var/lib/navishai/install.lock"
        FileUtils.mkdir_p(File.dirname(lock))
        holder = Process.spawn("flock", "-n", lock, "sleep", "10")
        sleep 0.1

        _stdout, stderr, status = run_installer(root, command, *arguments)

        assert_not status.success?
        assert_includes stderr, "another mutating operation is running"
        assert_empty docker_log(root)
      ensure
        Process.kill("TERM", holder) if holder
        Process.wait(holder) if holder
      end
    end
  end

  def test_direct_managed_backup_rejects_a_held_navishai_lock_before_docker
    Dir.mktmpdir do |root|
      release = "#{root}/opt/navishai/releases/current"
      FileUtils.mkdir_p("#{release}/ops/compose")
      %w[backup lib.sh].each do |name|
        FileUtils.cp(Rails.root.join("ops/compose/#{name}"), "#{release}/ops/compose/#{name}")
      end
      FileUtils.chmod(0o755, "#{release}/ops/compose/backup")
      lock = "#{root}/var/lib/navishai/install.lock"
      FileUtils.mkdir_p(File.dirname(lock))
      holder = Process.spawn("flock", "-n", lock, "sleep", "10")
      sleep 0.1

      _stdout, stderr, status = Open3.capture3(installer_environment(root), "#{release}/ops/compose/backup", "#{root}/archive")

      assert_not status.success?
      assert_includes stderr, "Another mutating NavishAI operation is running"
      assert_empty docker_log(root)
    ensure
      Process.kill("TERM", holder) if holder
      Process.wait(holder) if holder
    end
  end

  [ 0o644, 0o444, 0o404 ].each do |mode|
    define_method("test_rejects_answer_file_mode_#{mode.to_s(8)}") do
      Dir.mktmpdir do |root|
        answers = "#{root}/answers"
        File.write(answers, "NAVISHAI_APP_HOST=example.example\n")
        FileUtils.chmod(mode, answers)
        _stdout, stderr, status = run_installer(root, "setup", "missing.tar", "NAVISHAI_ANSWERS_FILE" => answers)

        assert_not status.success?
        refute_path_exists "#{root}/etc/navishai/env"
        assert_includes stderr, "answer file must not be readable"
      end
    end
  end

  def test_accepts_private_answer_file_before_bundle_validation
    Dir.mktmpdir do |root|
      answers = "#{root}/answers"
      File.write(answers, "NAVISHAI_APP_HOST=example.example\n")
      FileUtils.chmod(0o600, answers)

      _stdout, stderr, status = run_installer(root, "setup", "missing.tar", "NAVISHAI_ANSWERS_FILE" => answers)

      assert_not status.success?
      assert_includes stderr, "bundle not found"
      refute_includes stderr, "answer file"
    end
  end

  [ nil, "ca.crt", "server.crt", "server.key" ].each do |missing|
    define_method("test_rejects_incomplete_resume_state_#{missing || 'current'}") do
      Dir.mktmpdir do |root|
        bundle = build_bundle(root)
        FileUtils.mkdir_p("#{root}/etc/navishai/runner")
        File.write("#{root}/etc/navishai/env", "preserved-secret=value\n")
        %w[ca.crt server.crt server.key].each { |name| File.write("#{root}/etc/navishai/runner/#{name}", "tls-#{name}\n") unless name == missing }
        unless missing.nil?
          release = "#{root}/opt/navishai/releases/#{'a' * 64}"
          FileUtils.mkdir_p(release)
          File.symlink(release, "#{root}/opt/navishai/current")
        end

        _stdout, stderr, status = run_setup(root, bundle)

        assert_not status.success?
        assert_includes stderr, "incomplete setup state detected"
        assert_equal "preserved-secret=value\n", File.read("#{root}/etc/navishai/env")
        refute_includes docker_log(root), "image load"
      end
    end
  end

  def test_free_https_ports_allow_a_clean_setup
    Dir.mktmpdir do |root|
      bundle = build_bundle(root)

      _stdout, stderr, status = run_setup(root, bundle)

      assert status.success?, stderr
      assert_includes docker_log(root), "image load"
    end
  end

  def test_foreign_https_listener_rejects_before_install_mutation
    Dir.mktmpdir do |root|
      bundle = build_bundle(root)

      _stdout, stderr, status = run_setup(root, bundle, "FAKE_PORT_80" => "LISTEN\n")

      assert_not status.success?
      assert_includes stderr, "port 80 is in use"
      refute_path_exists "#{root}/etc/navishai/env"
      refute_path_exists "#{root}/opt/navishai/current"
      refute_includes docker_log(root), "image load"
    end
  end

  [ "0.0.0.0:80", "[::]:80" ].each do |listener|
    define_method("test_wildcard_listener_#{listener.tr('[]:.', '_')}_rejects_before_install_mutation") do
      Dir.mktmpdir do |root|
        bundle = build_bundle(root)

        _stdout, stderr, status = run_setup(root, bundle,
          "FAKE_PORT_80" => "LISTEN 0 0 #{listener} 0.0.0.0:*\\n")

        assert_not status.success?
        assert_includes stderr, "port 80 is in use"
        refute_path_exists "#{root}/etc/navishai/env"
        refute_includes docker_log(root), "image load"
      end
    end
  end

  def test_tailnet_only_listener_does_not_block_the_public_caddy_binding
    Dir.mktmpdir do |root|
      bundle = build_bundle(root)

      _stdout, stderr, status = run_setup(root, bundle,
        "FAKE_PORT_443" => "LISTEN 0 0 100.98.160.115:443 0.0.0.0:*\\n")

      assert status.success?, stderr
      assert_includes docker_log(root), "image load"
    end
  end

  def test_rejects_a_tailnet_listen_address_before_docker_or_state_mutation
    Dir.mktmpdir do |root|
      bundle = build_bundle(root)
      answers = "#{root}/answers"
      File.write(answers, "NAVISHAI_APP_HOST=install.example\nNAVISHAI_PUBLIC_LISTEN_ADDRESS=100.98.160.115\n")
      FileUtils.chmod(0o600, answers)

      _stdout, stderr, status = run_installer(root, "setup", bundle,
        "NAVISHAI_ANSWERS_FILE" => answers, "NAVISHAI_SETUP_ACCEPT" => "yes", "FAKE_ROUTE_SOURCE" => "100.98.160.115")

      assert_not status.success?
      assert_includes stderr, "public listen address must be globally routable"
      refute_path_exists "#{root}/etc/navishai/env"
      assert_empty docker_log(root)
    end
  end

  def test_managed_caddy_bindings_allow_setup_resume
    Dir.mktmpdir do |root|
      bundle = build_bundle(root)
      _stdout, stderr, status = run_setup(root, bundle)
      assert status.success?, stderr
      File.write("#{root}/docker.log", "")

      _stdout, stderr, status = run_setup(root, bundle,
        "FAKE_PORT_80" => "LISTEN\n", "FAKE_PORT_443" => "LISTEN\n",
        "FAKE_PORT_CONTAINER" => "caddy-id", "FAKE_PORT_LABELS" => "navishai caddy", "FAKE_PORT_BINDING" => "80")

      assert status.success?, stderr
      assert_includes docker_log(root), "ps --filter publish=80"
    end
  end

  def test_caddy_with_another_host_port_does_not_excuse_foreign_port_80
    Dir.mktmpdir do |root|
      bundle = build_bundle(root)
      _stdout, stderr, status = run_setup(root, bundle)
      assert status.success?, stderr
      File.write("#{root}/docker.log", "")

      _stdout, stderr, status = run_setup(root, bundle,
        "FAKE_PORT_80" => "LISTEN\n", "FAKE_PORT_CONTAINER" => "caddy-id", "FAKE_PORT_LABELS" => "navishai caddy")

      assert_not status.success?
      assert_includes stderr, "non-Docker service"
      refute_includes docker_log(root), "image load"
    end
  end

  def test_https_port_inspection_failure_rejects_resume
    Dir.mktmpdir do |root|
      bundle = build_bundle(root)
      _stdout, stderr, status = run_setup(root, bundle)
      assert status.success?, stderr

      _stdout, stderr, status = run_setup(root, bundle,
        "FAKE_PORT_80" => "LISTEN\n", "FAKE_PORT_CONTAINER" => "caddy-id", "DOCKER_FAIL_MATCH" => "inspect --format")

      assert_not status.success?
      assert_includes stderr, "cannot inspect port 80 ownership"
    end
  end

  [ "install.invalid", "INSTALL.TEST.", "localhost" ].each do |host|
    define_method("test_rejects_reserved_hostname_#{host.tr('.', '_')}") do
      Dir.mktmpdir do |root|
        answers = "#{root}/answers"
        File.write(answers, "NAVISHAI_APP_HOST=#{host}\n")
        FileUtils.chmod(0o600, answers)

        _stdout, stderr, status = run_installer(root, "setup", "missing.tar", "NAVISHAI_ANSWERS_FILE" => answers)

        assert_not status.success?
        assert_includes stderr, "a public hostname is required"
        refute_path_exists "#{root}/etc/navishai/env"
      end
    end
  end

  [ ".", "a..example.com", "-bad.example.com", "bad-.example.com", "127.0.0.1" ].each do |host|
    define_method("test_rejects_malformed_public_hostname_#{host.tr('-.', '_')}") do
      Dir.mktmpdir do |root|
        bundle = build_bundle(root)
        answers = "#{root}/answers"
        File.write(answers, "NAVISHAI_APP_HOST=#{host}\n")
        FileUtils.chmod(0o600, answers)

        _stdout, stderr, status = run_installer(root, "setup", bundle,
          "NAVISHAI_ANSWERS_FILE" => answers, "NAVISHAI_SETUP_ACCEPT" => "yes")

        assert_not status.success?
        assert_includes stderr, "a public hostname is required"
        refute_path_exists "#{root}/etc/navishai/env"
        refute_path_exists "#{root}/opt/navishai/current"
        assert_empty docker_log(root)
      end
    end
  end

  def test_backup_uses_installed_compose_context_despite_caller_values
    Dir.mktmpdir do |root|
      install = "#{root}/opt/navishai/current"
      FileUtils.mkdir_p("#{install}/ops/compose")
      FileUtils.mkdir_p("#{root}/etc/navishai")
      File.write("#{root}/etc/navishai/env", "value=true\n")
      %w[ backup verify_backup ].each do |name|
        File.write("#{install}/ops/compose/#{name}", "#!/bin/sh\nprintf '%s|%s|%s|%s\\n' \"$COMPOSE_PROJECT_NAME\" \"$COMPOSE_FILE\" \"$COMPOSE_ENV_FILES\" \"$PWD\" >>\"$OPERATION_LOG\"\n")
        FileUtils.chmod(0o755, "#{install}/ops/compose/#{name}")
      end
      log = "#{root}/operation.log"
      override = "#{root}/local-ca.yaml"
      File.write(override, "services: {}\n")
      _stdout, stderr, status = run_installer(root, "backup", "archive", "OPERATION_LOG" => log,
        "COMPOSE_PROJECT_NAME" => "wrong", "COMPOSE_FILE" => "/wrong", "COMPOSE_ENV_FILES" => "/wrong.env",
        "NAVISHAI_TEST_COMPOSE_OVERRIDE" => override)

      assert status.success?, stderr
      lines = File.readlines(log, chomp: true)
      assert_equal 2, lines.length
      lines.each { |line| assert_includes line, "navishai|#{install}/compose.yaml:#{install}/ops/installer/compose.yaml:#{override}|#{root}/etc/navishai/env|" }
    end
  end

  def test_restore_without_confirmation_does_not_call_helper
    Dir.mktmpdir do |root|
      _stdout, stderr, status = run_installer(root, "restore", "archive")

      assert_not status.success?
      assert_includes stderr, "usage: navishai restore"
    end
  end

  def test_managed_restore_selects_exact_release_identity_before_loading_or_promoting
    Dir.mktmpdir do |root|
      old_id = "a" * 64
      selected_id = "b" * 64
      old = restore_release(root, old_id, "same-source\n", "old-images\n", "old")
      selected = restore_release(root, selected_id, "same-source\n", "selected-images\n", "selected")
      FileUtils.mkdir_p("#{root}/etc/navishai")
      File.write("#{root}/etc/navishai/env", "value=true\n")
      FileUtils.mkdir_p("#{root}/opt/navishai")
      File.symlink(old, "#{root}/opt/navishai/current")
      archive = restore_archive(root, selected_id, Digest::SHA256.file("#{selected}/images.tar").hexdigest)
      override = "#{root}/local-ca.yaml"
      File.write(override, "services: {}\n")

      _stdout, stderr, status = run_installer(root, "restore", archive, "--confirm-destroy",
        "RESTORE_LOG" => "#{root}/restore.log", "NAVISHAI_TEST_COMPOSE_OVERRIDE" => override)

      assert status.success?, stderr
      assert_equal selected, File.realpath("#{root}/opt/navishai/current")
      log = File.read("#{root}/restore.log")
      assert_includes log, "verify-old"
      assert_includes log, "restore-selected"
      assert_includes docker_log(root), "image load -i #{selected}/images.tar"
      assert_includes docker_log(root), "up -d --wait supermemory runner web jobs caddy"
      assert_includes docker_log(root), "-f #{override} up -d --wait supermemory runner web jobs caddy"
    end
  end

  def test_managed_restore_rejects_failed_verification_before_stopping_or_loading
    Dir.mktmpdir do |root|
      release = restore_release(root, "a" * 64, "same-source\n", "images\n", "only")
      FileUtils.mkdir_p("#{root}/etc/navishai")
      File.write("#{root}/etc/navishai/env", "value=true\n")
      FileUtils.mkdir_p("#{root}/opt/navishai")
      File.symlink(release, "#{root}/opt/navishai/current")
      archive = restore_archive(root, "a" * 64, Digest::SHA256.file("#{release}/images.tar").hexdigest)

      _stdout, _stderr, status = run_installer(root, "restore", archive, "--confirm-destroy", "FAKE_VERIFY_FAIL" => "1")

      assert_not status.success?
      refute_includes docker_log(root), "stop caddy"
      refute_includes docker_log(root), "image load"
      assert_equal release, File.realpath("#{root}/opt/navishai/current")
    end
  end

  def test_managed_restore_image_load_failure_keeps_current_and_requires_restore
    Dir.mktmpdir do |root|
      old = restore_release(root, "a" * 64, "same-source\n", "old\n", "old")
      selected = restore_release(root, "b" * 64, "same-source\n", "selected\n", "selected")
      FileUtils.mkdir_p([ "#{root}/etc/navishai", "#{root}/opt/navishai" ])
      File.write("#{root}/etc/navishai/env", "value=true\n")
      File.symlink(old, "#{root}/opt/navishai/current")
      archive = restore_archive(root, "b" * 64, Digest::SHA256.file("#{selected}/images.tar").hexdigest)

      _stdout, stderr, status = run_installer(root, "restore", archive, "--confirm-destroy", "DOCKER_FAIL_MATCH" => "image load -i")

      assert_not status.success?
      assert_includes stderr, "restore image_load failed"
      assert_equal old, File.realpath("#{root}/opt/navishai/current")
      assert_includes File.read("#{root}/var/lib/navishai/install.json"), "restore_image_load_restore_required"
      assert_operator docker_log(root).rindex("stop caddy jobs web runner supermemory"), :>, docker_log(root).index("image load -i")
    end
  end

  def test_managed_restore_helper_failure_keeps_current_and_requires_restore
    Dir.mktmpdir do |root|
      old = restore_release(root, "a" * 64, "same-source\n", "old\n", "old")
      selected = restore_release(root, "b" * 64, "same-source\n", "selected\n", "selected")
      FileUtils.mkdir_p([ "#{root}/etc/navishai", "#{root}/opt/navishai" ])
      File.write("#{root}/etc/navishai/env", "value=true\n")
      File.symlink(old, "#{root}/opt/navishai/current")
      archive = restore_archive(root, "b" * 64, Digest::SHA256.file("#{selected}/images.tar").hexdigest)

      _stdout, stderr, status = run_installer(root, "restore", archive, "--confirm-destroy",
        "RESTORE_LOG" => "#{root}/restore.log", "FAKE_RESTORE_FAIL" => "1")

      assert_not status.success?
      assert_includes stderr, "restore data failed"
      assert_equal old, File.realpath("#{root}/opt/navishai/current")
      assert_includes File.read("#{root}/var/lib/navishai/install.json"), "restore_data_restore_required"
      refute_includes File.read("#{root}/var/lib/navishai/install.json"), "restore_completed"
      assert_equal [ "verify-old", "restore-selected" ], File.readlines("#{root}/restore.log", chomp: true)
      log = docker_log(root)
      assert_includes log, "image load -i #{selected}/images.tar"
      assert_operator log.rindex("stop caddy jobs web runner supermemory"), :>, log.index("image load -i #{selected}/images.tar")
    end
  end

  def test_managed_restore_readiness_failure_keeps_current_and_requires_restore
    Dir.mktmpdir do |root|
      old = restore_release(root, "a" * 64, "same-source\n", "old\n", "old")
      selected = restore_release(root, "b" * 64, "same-source\n", "selected\n", "selected")
      FileUtils.mkdir_p([ "#{root}/etc/navishai", "#{root}/opt/navishai" ])
      File.write("#{root}/etc/navishai/env", "value=true\n")
      File.symlink(old, "#{root}/opt/navishai/current")
      archive = restore_archive(root, "b" * 64, Digest::SHA256.file("#{selected}/images.tar").hexdigest)

      _stdout, stderr, status = run_installer(root, "restore", archive, "--confirm-destroy",
        "RESTORE_LOG" => "#{root}/restore.log", "DOCKER_FAIL_MATCH" => "up -d --wait supermemory runner web jobs caddy")

      assert_not status.success?
      assert_includes stderr, "restore readiness failed"
      assert_equal old, File.realpath("#{root}/opt/navishai/current")
      state = File.read("#{root}/var/lib/navishai/install.json")
      assert_includes state, "restore_readiness_restore_required"
      refute_includes state, "restore_completed"
    end
  end

  def test_rejects_tampered_helper_before_docker_or_state_mutation
    Dir.mktmpdir do |root|
      bundle = build_bundle(root)
      Dir.mktmpdir do |unpacked|
        system("tar", "-xf", bundle, "-C", unpacked, exception: true)
        File.write("#{unpacked}/release/ops/compose/backup", "tampered\n")
        system("tar", "-cf", bundle, "-C", unpacked, "SHA256SUMS", "images.tar", "release", exception: true)
      end

      _stdout, stderr, status = run_setup(root, bundle)

      assert_not status.success?
      assert_includes stderr, "bundle manifest is incomplete or unsafe"
      refute_path_exists "#{root}/etc/navishai/env"
      assert_empty docker_log(root)
    end
  end

  def test_rejects_truncated_manifest_before_docker_or_state_mutation
    Dir.mktmpdir do |root|
      bundle = build_bundle(root)
      Dir.mktmpdir do |unpacked|
        system("tar", "-xf", bundle, "-C", unpacked, exception: true)
        File.write("#{unpacked}/SHA256SUMS", File.read("#{unpacked}/SHA256SUMS").lines.first)
        system("tar", "-cf", bundle, "-C", unpacked, "SHA256SUMS", "images.tar", "release", exception: true)
      end

      _stdout, stderr, status = run_setup(root, bundle)

      assert_not status.success?
      assert_includes stderr, "bundle manifest is incomplete or unsafe"
      assert_empty docker_log(root)
    end
  end

  def test_rejects_external_manifest_path_before_docker_or_state_mutation
    Dir.mktmpdir do |root|
      bundle = build_bundle(root)
      Dir.mktmpdir do |unpacked|
        system("tar", "-xf", bundle, "-C", unpacked, exception: true)
        File.open("#{unpacked}/SHA256SUMS", "a") { |file| file.puts("#{"0" * 64}  /etc/passwd") }
        system("tar", "-cf", bundle, "-C", unpacked, "SHA256SUMS", "images.tar", "release", exception: true)
      end

      _stdout, stderr, status = run_setup(root, bundle)

      assert_not status.success?
      assert_includes stderr, "bundle manifest is incomplete or unsafe"
      assert_empty docker_log(root)
    end
  end

  def test_rejects_secret_payload_before_docker_or_state_mutation
    Dir.mktmpdir do |root|
      bundle = build_bundle(root, "release/ops/secrets/token" => "do not ship\n")

      _stdout, stderr, status = run_setup(root, bundle)

      assert_not status.success?
      assert_includes stderr, "unexpected payload"
      refute_path_exists "#{root}/etc/navishai/env"
      assert_empty docker_log(root)
    end
  end

  def test_rejects_symlink_payload_before_docker_or_state_mutation
    Dir.mktmpdir do |root|
      bundle = build_bundle(root)
      Dir.mktmpdir do |unpacked|
        system("tar", "-xf", bundle, "-C", unpacked, exception: true)
        FileUtils.rm("#{unpacked}/release/script/generate_runner_tls")
        File.symlink("/etc/passwd", "#{unpacked}/release/script/generate_runner_tls")
        system("tar", "-cf", bundle, "-C", unpacked, "SHA256SUMS", "images.tar", "release", exception: true)
      end

      _stdout, stderr, status = run_setup(root, bundle)

      assert_not status.success?
      assert_includes stderr, "unsupported entry types"
      refute_path_exists "#{root}/etc/navishai/env"
      assert_empty docker_log(root)
    end
  end

  def test_setup_requires_explicit_confirmation_before_installing_a_release
    Dir.mktmpdir do |root|
      bundle = build_bundle(root)
      answers = "#{root}/answers"
      File.write(answers, "NAVISHAI_APP_HOST=install.example\nNAVISHAI_PUBLIC_LISTEN_ADDRESS=203.0.113.10\n")
      FileUtils.chmod(0o600, answers)

      stdout, stderr, status = run_installer(root, "setup", bundle, "NAVISHAI_ANSWERS_FILE" => answers)

      assert_not status.success?
      assert_includes stderr, "NAVISHAI_SETUP_ACCEPT=yes"
      assert_includes stdout, "https://install.example on ports 80 and 443"
      assert_includes stdout, "persistent Docker volumes"
      refute_path_exists "#{root}/etc/navishai/env"
      refute_path_exists "#{root}/opt/navishai/current"
      refute_includes docker_log(root), "image load"
    end
  end

  def test_invalid_answer_hostname_stops_before_bundle_or_docker_mutation
    Dir.mktmpdir do |root|
      bundle = build_bundle(root)
      answers = "#{root}/answers"
      File.write(answers, "NAVISHAI_APP_HOST=install.invalid\n")
      FileUtils.chmod(0o600, answers)

      _stdout, stderr, status = run_installer(root, "setup", bundle,
        "NAVISHAI_ANSWERS_FILE" => answers, "NAVISHAI_SETUP_ACCEPT" => "yes")

      assert_not status.success?
      assert_includes stderr, "a public hostname is required"
      refute_path_exists "#{root}/etc/navishai/env"
      refute_path_exists "#{root}/opt/navishai/current"
      assert_empty docker_log(root)
    end
  end

  def test_setup_rejects_a_different_release_without_replacing_existing_state
    Dir.mktmpdir do |root|
      first = build_bundle(root, "release/ops/compose/backup" => "first\n")
      second = build_bundle(root, "release/ops/compose/backup" => "second\n")

      _stdout, first_stderr, first_status = run_setup(root, first)
      assert first_status.success?, first_stderr
      first_release = File.realpath("#{root}/opt/navishai/current")
      environment_before = File.read("#{root}/etc/navishai/env")
      tls_before = Dir["#{root}/etc/navishai/runner/*"].to_h { |path| [ File.basename(path), Digest::SHA256.file(path).hexdigest ] }
      File.write("#{root}/docker.log", "")

      _stdout, second_stderr, second_status = run_setup(root, second)

      assert_not second_status.success?
      assert_includes second_stderr, "installed release differs"
      assert_equal first_release, File.realpath("#{root}/opt/navishai/current")
      assert_equal environment_before, File.read("#{root}/etc/navishai/env")
      assert_equal tls_before, Dir["#{root}/etc/navishai/runner/*"].to_h { |path| [ File.basename(path), Digest::SHA256.file(path).hexdigest ] }
      refute_includes docker_log(root), "image load"
    end
  end

  def test_identical_payloads_from_different_staging_roots_keep_the_same_release_identity
    Dir.mktmpdir do |root|
      first = build_bundle(root)
      second = build_bundle(root)

      _stdout, first_stderr, first_status = run_setup(root, first)
      assert first_status.success?, first_stderr
      first_release = File.realpath("#{root}/opt/navishai/current")
      _stdout, second_stderr, second_status = run_setup(root, second)
      assert second_status.success?, second_stderr

      assert_equal first_release, File.realpath("#{root}/opt/navishai/current")
    end
  end

  def test_answer_file_setup_does_not_emit_the_bootstrap_token
    Dir.mktmpdir do |root|
      bundle = build_bundle(root)

      stdout, stderr, status = run_setup(root, bundle)

      assert status.success?, stderr
      assert_includes stdout, "Infrastructure and HTTPS are ready at https://install.example."
      curl = docker_log(root).lines.find { |line| line.include?("https://install.example/up") }
      assert_includes curl, "--connect-timeout 10"
      assert_includes curl, "--max-time 30"
      assert_includes curl, "--write-out %{http_code}"
      refute_includes curl, "--insecure"
      assert_includes stdout, "Create the first Owner at https://install.example/setup."
      assert_includes stdout, "navishai reveal-owner-token --confirm-reveal"
      assert_includes stdout, "Open setup if you have not created the first Owner."
      refute_includes stdout, "NAVISHAI_BOOTSTRAP_TOKEN="
      refute_includes stdout, "First-Owner code"
    end
  end

  def test_https_failure_preserves_a_same_release_for_retry
    Dir.mktmpdir do |root|
      bundle = build_bundle(root)

      _stdout, stderr, status = run_setup(root, bundle, "FAKE_HTTPS_FAIL" => "1")

      assert_not status.success?
      assert_includes stderr, "services started, but HTTPS could not be verified"
      assert_includes File.read("#{root}/var/lib/navishai/install.json"), "https_unverified"
      environment = File.read("#{root}/etc/navishai/env")
      current = File.realpath("#{root}/opt/navishai/current")
      _stdout, retry_stderr, retry_status = run_setup(root, bundle)
      assert retry_status.success?, retry_stderr
      assert_equal environment, File.read("#{root}/etc/navishai/env")
      assert_equal current, File.realpath("#{root}/opt/navishai/current")
    end
  end

  def test_https_verification_waits_for_certificate_issuance_within_the_bounded_window
    Dir.mktmpdir do |root|
      bundle = build_bundle(root)

      stdout, stderr, status = run_setup(root, bundle, "FAKE_HTTPS_FAIL_COUNT" => "2",
        "NAVISHAI_HTTPS_WAIT_SECONDS" => "30", "NAVISHAI_TEST_HTTPS_INTERVAL" => "0")

      assert status.success?, stderr
      assert_includes stderr, "waiting for HTTPS"
      assert_includes stdout, "Infrastructure and HTTPS are ready"
      assert_equal 3, docker_log(root).lines.count { |line| line.include?("https://install.example/up") }
      assert_includes File.read("#{root}/var/lib/navishai/install.json"), "https_verified"
    end
  end

  def test_https_verification_gives_up_after_the_bounded_window_without_a_200
    Dir.mktmpdir do |root|
      bundle = build_bundle(root)

      _stdout, stderr, status = run_setup(root, bundle, "FAKE_HTTPS_STATUS" => "302",
        "NAVISHAI_HTTPS_WAIT_SECONDS" => "1", "NAVISHAI_TEST_HTTPS_INTERVAL" => "0")

      assert_not status.success?
      assert_includes stderr, "waiting for HTTPS"
      assert_includes stderr, "HTTPS could not be verified"
      assert_operator docker_log(root).lines.count { |line| line.include?("https://install.example/up") }, :>=, 2
      assert_includes File.read("#{root}/var/lib/navishai/install.json"), "https_unverified"
    end
  end

  def test_https_redirect_does_not_count_as_readiness
    Dir.mktmpdir do |root|
      bundle = build_bundle(root)

      _stdout, stderr, status = run_setup(root, bundle, "FAKE_HTTPS_STATUS" => "302")

      assert_not status.success?
      assert_includes stderr, "HTTPS could not be verified"
      assert_includes File.read("#{root}/var/lib/navishai/install.json"), "https_unverified"
    end
  end

  def test_setup_image_load_failure_keeps_release_complete_for_safe_retry
    Dir.mktmpdir do |root|
      bundle = build_bundle(root)

      _stdout, _stderr, status = run_setup(root, bundle, "DOCKER_FAIL_MATCH" => "image load -i")

      assert_not status.success?
      refute_path_exists "#{root}/opt/navishai/current"
      refute_path_exists "#{root}/etc/navishai/env"
      release = Dir.glob("#{root}/opt/navishai/releases/*").first
      assert_path_exists "#{release}/images.tar"
      assert_path_exists "#{release}/SOURCE_COMMIT"
      _stdout, retry_stderr, retry_status = run_setup(root, bundle)
      assert retry_status.success?, retry_stderr
      assert_equal release, File.realpath("#{root}/opt/navishai/current")
    end
  end

  def test_release_publish_interruption_leaves_no_visible_release_and_retries
    Dir.mktmpdir do |root|
      bundle = build_bundle(root)

      _stdout, _stderr, status = run_setup(root, bundle, "NAVISHAI_TEST_FAIL_BEFORE_RELEASE_PUBLISH" => "1")

      assert_not status.success?
      assert_empty Dir.glob("#{root}/opt/navishai/releases/[!.]*")
      refute_path_exists "#{root}/opt/navishai/current"
      refute_path_exists "#{root}/etc/navishai/env"
      _stdout, retry_stderr, retry_status = run_setup(root, bundle)
      assert retry_status.success?, retry_stderr
      assert_path_exists File.realpath("#{root}/opt/navishai/current")
    end
  end

  def test_normalizes_a_valid_public_hostname_before_writing_environment
    Dir.mktmpdir do |root|
      bundle = build_bundle(root)
      answers = "#{root}/answers"
      File.write(answers, "NAVISHAI_APP_HOST=Install.Example.\nNAVISHAI_PUBLIC_LISTEN_ADDRESS=203.0.113.10\n")
      FileUtils.chmod(0o600, answers)

      _stdout, stderr, status = run_installer(root, "setup", bundle,
        "NAVISHAI_ANSWERS_FILE" => answers, "NAVISHAI_SETUP_ACCEPT" => "yes")

      assert status.success?, stderr
      environment = File.read("#{root}/etc/navishai/env")
      assert_includes environment, "NAVISHAI_APP_HOST=install.example"
      assert_includes environment, "NAVISHAI_PUBLIC_LISTEN_ADDRESS=203.0.113.10"
    end
  end

  def test_answer_file_setup_does_not_emit_the_actual_token_under_a_pty
    Dir.mktmpdir do |root|
      bundle = build_bundle(root)
      answers = "#{root}/answers"
      transcript = "#{root}/setup.typescript"
      File.write(answers, "NAVISHAI_APP_HOST=install.example\nNAVISHAI_PUBLIC_LISTEN_ADDRESS=203.0.113.10\n")
      FileUtils.chmod(0o600, answers)
      environment = installer_environment(root, "NAVISHAI_ANSWERS_FILE" => answers, "NAVISHAI_SETUP_ACCEPT" => "yes")
      command = Shellwords.join([ Rails.root.join("ops/installer/navishai").to_s, "setup", bundle ])

      _stdout, stderr, status = Open3.capture3(environment, "script", "--quiet", "--return", "--command", command, transcript)

      assert status.success?, stderr
      token = File.read("#{root}/etc/navishai/env")[/^NAVISHAI_BOOTSTRAP_TOKEN=(.+)$/, 1]
      assert_not_nil token
      refute_includes File.read(transcript), token
    end
  end

  def test_renew_owner_token_rotates_the_token_and_expiry_only_when_rails_allows_renewal
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p("#{root}/etc/navishai")
      File.write("#{root}/etc/navishai/env", "NAVISHAI_DATABASE_PASSWORD=preserved\nNAVISHAI_BOOTSTRAP_TOKEN=old-token\nNAVISHAI_BOOTSTRAP_TOKEN_EXPIRES_AT=2026-01-01T00:00:00Z\n")

      stdout, stderr, status = run_installer(root, "renew-owner-token")

      assert status.success?, stderr
      environment = File.read("#{root}/etc/navishai/env")
      assert_includes environment, "NAVISHAI_DATABASE_PASSWORD=preserved\n"
      refute_includes environment, "old-token"
      refute_includes environment, "2026-01-01T00:00:00Z"
      token = environment[/^NAVISHAI_BOOTSTRAP_TOKEN=(\S+)$/, 1]
      assert_match(/\A[0-9a-f]{64}\z/, token)
      assert_operator Time.iso8601(environment[/^NAVISHAI_BOOTSTRAP_TOKEN_EXPIRES_AT=(\S+)$/, 1]), :>, 23.hours.from_now
      refute_includes stdout, token
      assert_includes stdout, "reveal-owner-token --confirm-reveal"
      log = docker_log(root)
      assert_operator log.index("navishai:first_owner:renewable"), :<, log.index("up -d --wait web jobs")
    end
  end

  def test_renew_owner_token_refuses_after_first_owner_setup_without_changing_environment
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p("#{root}/etc/navishai")
      original = "NAVISHAI_BOOTSTRAP_TOKEN=old-token\nNAVISHAI_BOOTSTRAP_TOKEN_EXPIRES_AT=2026-01-01T00:00:00Z\n"
      File.write("#{root}/etc/navishai/env", original)

      _stdout, stderr, status = run_installer(root, "renew-owner-token", "DOCKER_FAIL_MATCH" => "navishai:first_owner:renewable")

      assert_not status.success?
      assert_includes stderr, "cannot be renewed"
      assert_equal original, File.read("#{root}/etc/navishai/env")
      refute_includes docker_log(root), "up -d"
    end
  end

  def test_renew_owner_token_keeps_the_new_token_after_restart_failure_and_retries
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p("#{root}/etc/navishai")
      File.write("#{root}/etc/navishai/env", "NAVISHAI_BOOTSTRAP_TOKEN=old-token\nNAVISHAI_BOOTSTRAP_TOKEN_EXPIRES_AT=2026-01-01T00:00:00Z\n")

      _stdout, _stderr, first = run_installer(root, "renew-owner-token", "DOCKER_FAIL_MATCH" => "up -d --wait web jobs")

      assert_not first.success?
      refute_includes File.read("#{root}/etc/navishai/env"), "old-token"

      _stdout, stderr, second = run_installer(root, "renew-owner-token")
      assert second.success?, stderr
    end
  end

  def test_reveal_owner_token_requires_explicit_confirmation
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p("#{root}/etc/navishai")
      File.write("#{root}/etc/navishai/env", "NAVISHAI_BOOTSTRAP_TOKEN=secret-token\n")

      _stdout, stderr, status = run_installer(root, "reveal-owner-token")
      assert_not status.success?
      assert_includes stderr, "usage: navishai reveal-owner-token"

      stdout, stderr, status = run_installer(root, "reveal-owner-token", "--confirm-reveal")
      assert_not status.success?
      assert_empty stdout
      assert_includes stderr, "trusted interactive terminal"
    end
  end

  def test_reveal_owner_token_writes_only_to_the_controlling_terminal
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p("#{root}/etc/navishai")
      token = "test-terminal-token"
      File.write("#{root}/etc/navishai/env", "NAVISHAI_BOOTSTRAP_TOKEN=#{token}\n")
      stdout = "#{root}/stdout"
      stderr = "#{root}/stderr"
      transcript = "#{root}/reveal.typescript"
      command = Shellwords.join([ Rails.root.join("ops/installer/navishai").to_s, "reveal-owner-token", "--confirm-reveal" ])
      command = "#{command} >#{Shellwords.escape(stdout)} 2>#{Shellwords.escape(stderr)}"

      _output, script_stderr, status = Open3.capture3(installer_environment(root), "script", "--quiet", "--return", "--command", command, transcript)

      assert status.success?, script_stderr
      assert_includes File.read(transcript), token
      refute_includes File.read(stdout), token
      refute_includes File.read(stderr), token
    end
  end

  def test_test_compose_override_applies_before_every_setup_compose_command
    Dir.mktmpdir do |root|
      bundle = build_bundle(root)
      override = "#{root}/local-ca.yaml"
      File.write(override, "services: {}\n")

      _stdout, stderr, status = run_setup(root, bundle, "NAVISHAI_TEST_COMPOSE_OVERRIDE" => override)

      assert status.success?, stderr
      docker_log(root).lines.grep(/--project-name/).each do |line|
        assert_includes line, "-f #{override}"
      end
    end
  end

  def test_secret_reference_accepts_unterminated_private_file_without_outputting_value
    Dir.mktmpdir do |root|
      secret = "#{root}/memory-key"
      File.write(secret, "private-token")
      FileUtils.chmod(0o600, secret)
      answers = "#{root}/answers"
      File.write(answers, "NAVISHAI_APP_HOST=install.example\nNAVISHAI_SUPERMEMORY_API_KEY_FILE=#{secret}")
      FileUtils.chmod(0o600, answers)

      stdout, stderr, status = run_installer(root, "setup", "missing.tar", "NAVISHAI_ANSWERS_FILE" => answers)

      assert_not status.success?
      assert_includes stderr, "bundle not found"
      refute_includes "#{stdout}#{stderr}", "private-token"
    end
  end

  def test_secret_reference_rejects_duplicate_unknown_or_unsafe_file_before_docker
    Dir.mktmpdir do |root|
      secret = "#{root}/memory-key"
      File.write(secret, "key\nsecond")
      FileUtils.chmod(0o600, secret)
      answers = "#{root}/answers"
      File.write(answers, "NAVISHAI_APP_HOST=install.example\nNAVISHAI_APP_HOST=other.example\nNAVISHAI_SUPERMEMORY_API_KEY_FILE=#{secret}")
      FileUtils.chmod(0o600, answers)

      _stdout, stderr, status = run_installer(root, "setup", "missing.tar", "NAVISHAI_ANSWERS_FILE" => answers)

      assert_not status.success?
      assert_includes stderr, "duplicate field"
      assert_empty docker_log(root)
    end
  end

  def test_upgrade_rejects_installed_postgres_15_for_pinned_pg16_target_before_stopping_services
    Dir.mktmpdir do |root|
      bundle = build_bundle(root)
      _stdout, setup_stderr, setup_status = run_setup(root, bundle)
      assert setup_status.success?, setup_stderr
      current = File.realpath("#{root}/opt/navishai/current")
      File.write("#{current}/ops/compose/upgrade_preflight", "#!/bin/sh\nexit 0\n")
      FileUtils.chmod(0o755, "#{current}/ops/compose/upgrade_preflight")
      File.write("#{root}/backup", "verified\n")
      File.write("#{root}/docker.log", "")

      _stdout, stderr, status = run_installer(root, "upgrade", "#{root}/backup", bundle, "--confirm-apply",
        "DOCKER_CONFIG_JSON" => { services: { postgres: { image: "pgvector/pgvector:0.8.6-pg16@sha256:#{'a' * 64}" } } }.to_json,
        "DOCKER_POSTGRES_VERSION" => "150000")

      assert_not status.success?
      assert_includes stderr, "does not match installed PostgreSQL 15"
      assert_equal current, File.realpath("#{root}/opt/navishai/current")
      refute_includes docker_log(root), "stop caddy"
      refute_includes docker_log(root), "image load"
    end
  end

  def test_upgrade_rejects_changed_images_before_stopping_services_or_promoting_target
    Dir.mktmpdir do |root|
      bundle = build_bundle(root)
      target = build_bundle(root, "release/ops/compose/backup" => "target-backup\n", "images.tar" => "changed images\n")
      _stdout, setup_stderr, setup_status = run_setup(root, bundle)
      assert setup_status.success?, setup_stderr
      current = File.realpath("#{root}/opt/navishai/current")
      File.write("#{current}/ops/compose/upgrade_preflight", "#!/bin/sh\nexit 0\n")
      FileUtils.chmod(0o755, "#{current}/ops/compose/upgrade_preflight")
      File.write("#{root}/backup", "verified\n")
      File.write("#{root}/docker.log", "")

      _stdout, stderr, status = run_installer(root, "upgrade", "#{root}/backup", target, "--confirm-apply",
        "DOCKER_CONFIG_JSON" => { services: { postgres: { image: "pgvector/pgvector:0.8.6-pg16@sha256:#{'a' * 64}" } } }.to_json,
        "DOCKER_POSTGRES_VERSION" => "160000")

      assert_not status.success?
      assert_includes stderr, "changed-image upgrades are temporarily unavailable"
      assert_equal current, File.realpath("#{root}/opt/navishai/current")
      refute_includes docker_log(root), "stop caddy"
      refute_includes docker_log(root), "image load"
    end
  end

  def test_upgrade_rejects_changed_service_reference_with_the_same_image_archive
    Dir.mktmpdir do |root|
      bundle = build_bundle(root)
      target = build_bundle(root, "release/ops/compose/backup" => "target-backup\n")
      _stdout, setup_stderr, setup_status = run_setup(root, bundle)
      assert setup_status.success?, setup_stderr
      current = File.realpath("#{root}/opt/navishai/current")
      File.write("#{current}/ops/compose/upgrade_preflight", "#!/bin/sh\nexit 0\n")
      FileUtils.chmod(0o755, "#{current}/ops/compose/upgrade_preflight")
      File.write("#{root}/backup", "verified\n")
      File.write("#{root}/docker.log", "")
      postgres = "pgvector/pgvector:0.8.6-pg16@sha256:#{'a' * 64}"

      _stdout, stderr, status = run_installer(root, "upgrade", "#{root}/backup", target, "--confirm-apply",
        "DOCKER_TARGET_CONFIG_JSON" => { services: { postgres: { image: postgres }, web: { image: "navishai-rails:new" } } }.to_json,
        "DOCKER_CURRENT_CONFIG_JSON" => { services: { postgres: { image: postgres }, web: { image: "navishai-rails:local" } } }.to_json)

      assert_not status.success?
      assert_includes stderr, "target service image references differ"
      assert_equal current, File.realpath("#{root}/opt/navishai/current")
      refute_includes docker_log(root), "stop caddy"
      refute_includes docker_log(root), "image load"
    end
  end

  def test_upgrade_accepts_a_changed_application_image_when_infra_and_schema_stay_the_same
    Dir.mktmpdir do |root|
      current_images = docker_save_images(root, rails: "rails-old", runner: "runner-1", memory: "memory-1")
      target_images = docker_save_images(root, rails: "rails-new", runner: "runner-1", memory: "memory-1")
      bundle = build_bundle(root, "images.tar" => current_images)
      target = build_bundle(root, "images.tar" => target_images, "release/SOURCE_COMMIT" => "#{"b" * 40}\n", "release/ops/compose/backup" => "target-backup\n")
      _stdout, setup_stderr, setup_status = run_setup(root, bundle)
      assert setup_status.success?, setup_stderr
      current = ready_upgrade(root)
      password_line = File.read("#{root}/etc/navishai/env").lines.grep(/NAVISHAI_DATABASE_PASSWORD=/).first
      tls_before = runner_tls_digests(root)
      services = pinned_compose_services

      stdout, stderr, status = run_installer(root, "upgrade", "#{root}/backup", target, "--confirm-apply",
        upgrade_docker_env(services).merge("DOCKER_POSTGRES_VERSION" => "160000"))

      assert status.success?, stderr
      assert_includes File.read("#{root}/var/lib/navishai/install.json"), "upgrade_completed"
      refute_path_exists "#{root}/var/lib/navishai/upgrade-attempt.json"
      assert_not_equal current, File.realpath("#{root}/opt/navishai/current")
      assert_equal "b" * 40, File.read("#{root}/opt/navishai/current/SOURCE_COMMIT").strip
      env_after = File.read("#{root}/etc/navishai/env")
      assert_includes env_after, "NAVISHAI_SOURCE_COMMIT=#{'b' * 40}\n"
      assert_includes env_after, password_line
      assert_equal tls_before, runner_tls_digests(root)
      log = docker_log(root)
      assert_operator log.index("image load -i"), :<, log.index("stop caddy")
      assert_includes log, "db:migrate:status"
      refute_includes log, "db:prepare"
      refute_includes log, "down -v"
      refute_includes log, "volume rm"
      assert_includes stdout, "Application image upgrade completed"
    end
  end

  def test_upgrade_rejects_a_changed_runner_image_before_stopping_services
    Dir.mktmpdir do |root|
      current_images = docker_save_images(root, rails: "rails-1", runner: "runner-old", memory: "memory-1")
      target_images = docker_save_images(root, rails: "rails-1", runner: "runner-new", memory: "memory-1")
      bundle = build_bundle(root, "images.tar" => current_images)
      target = build_bundle(root, "images.tar" => target_images, "release/SOURCE_COMMIT" => "#{"b" * 40}\n")
      _stdout, setup_stderr, setup_status = run_setup(root, bundle)
      assert setup_status.success?, setup_stderr
      current = ready_upgrade(root)

      _stdout, stderr, status = run_installer(root, "upgrade", "#{root}/backup", target, "--confirm-apply",
        upgrade_docker_env(pinned_compose_services).merge("DOCKER_POSTGRES_VERSION" => "160000"))

      assert_not status.success?
      assert_includes stderr, "runner, memory, or other unsupported images"
      assert_equal current, File.realpath("#{root}/opt/navishai/current")
      refute_includes docker_log(root), "stop caddy"
    end
  end

  def test_upgrade_rejects_pending_schema_migrations_before_stopping_services
    Dir.mktmpdir do |root|
      current_images = docker_save_images(root, rails: "rails-old", runner: "runner-1", memory: "memory-1")
      target_images = docker_save_images(root, rails: "rails-new", runner: "runner-1", memory: "memory-1")
      bundle = build_bundle(root, "images.tar" => current_images)
      target = build_bundle(root, "images.tar" => target_images, "release/SOURCE_COMMIT" => "#{"b" * 40}\n")
      _stdout, setup_stderr, setup_status = run_setup(root, bundle)
      assert setup_status.success?, setup_stderr
      current = ready_upgrade(root)

      _stdout, stderr, status = run_installer(root, "upgrade", "#{root}/backup", target, "--confirm-apply",
        upgrade_docker_env(pinned_compose_services).merge(
          "DOCKER_POSTGRES_VERSION" => "160000",
          "DOCKER_MIGRATE_STATUS" => "   down     20260912210000  add_incompatible_change"
        ))

      assert_not status.success?
      assert_includes stderr, "pending schema migrations"
      assert_equal current, File.realpath("#{root}/opt/navishai/current")
      log = docker_log(root)
      assert_includes log, "image load -i"
      refute_includes log, "stop caddy"
    end
  end

  def test_upgrade_rejects_changed_service_topology_before_stopping_services
    Dir.mktmpdir do |root|
      bundle = build_bundle(root)
      target = build_bundle(root, "release/ops/compose/backup" => "target-backup\n")
      _stdout, setup_stderr, setup_status = run_setup(root, bundle)
      assert setup_status.success?, setup_stderr
      current = ready_upgrade(root)
      postgres = "pgvector/pgvector:0.8.6-pg16@sha256:#{'a' * 64}"

      _stdout, stderr, status = run_installer(root, "upgrade", "#{root}/backup", target, "--confirm-apply",
        "DOCKER_CURRENT_CONFIG_JSON" => { services: { postgres: { image: postgres } } }.to_json,
        "DOCKER_TARGET_CONFIG_JSON" => { services: { postgres: { image: postgres }, extra: { image: "busybox:latest" } } }.to_json,
        "DOCKER_POSTGRES_VERSION" => "160000")

      assert_not status.success?
      assert_includes stderr, "target service topology differs"
      assert_equal current, File.realpath("#{root}/opt/navishai/current")
      refute_includes docker_log(root), "stop caddy"
    end
  end

  def test_failed_application_image_health_restores_the_previous_release
    Dir.mktmpdir do |root|
      current_images = docker_save_images(root, rails: "rails-old", runner: "runner-1", memory: "memory-1")
      target_images = docker_save_images(root, rails: "rails-new", runner: "runner-1", memory: "memory-1")
      bundle = build_bundle(root, "images.tar" => current_images)
      target = build_bundle(root, "images.tar" => target_images, "release/SOURCE_COMMIT" => "#{"b" * 40}\n")
      _stdout, setup_stderr, setup_status = run_setup(root, bundle)
      assert setup_status.success?, setup_stderr
      current = ready_upgrade(root)
      tls_before = runner_tls_digests(root)

      _stdout, stderr, status = run_installer(root, "upgrade", "#{root}/backup", target, "--confirm-apply",
        upgrade_docker_env(pinned_compose_services).merge(
          "DOCKER_POSTGRES_VERSION" => "160000",
          "DOCKER_FAIL_MATCH" => "up -d --wait web jobs caddy",
          "DOCKER_FAIL_TIMES" => "1"
        ))

      assert_not status.success?
      assert_includes stderr, "restored previous application release"
      assert_equal current, File.realpath("#{root}/opt/navishai/current")
      assert_equal "a" * 40, File.read("#{root}/opt/navishai/current/SOURCE_COMMIT").strip
      assert_equal tls_before, runner_tls_digests(root)
      state = File.read("#{root}/var/lib/navishai/install.json")
      assert_includes state, "upgrade_app_image_recovered"
      refute_includes state, "upgrade_completed"
      refute_includes state, "restore_required"
      attempt = JSON.parse(File.read("#{root}/var/lib/navishai/upgrade-attempt.json"))
      assert_equal "recovered", attempt.fetch("outcome")

      File.write("#{root}/docker.log", "")
      _stdout, retry_stderr, retry_status = run_installer(root, "upgrade", "#{root}/backup", target, "--confirm-apply",
        upgrade_docker_env(pinned_compose_services).merge("DOCKER_POSTGRES_VERSION" => "160000"))

      assert_not retry_status.success?
      assert_includes retry_stderr, "rolled back after a failed promotion"
      refute_includes docker_log(root), "stop caddy"
    end
  end

  def test_unrecoverable_application_image_rollback_requires_restore
    Dir.mktmpdir do |root|
      current_images = docker_save_images(root, rails: "rails-old", runner: "runner-1", memory: "memory-1")
      target_images = docker_save_images(root, rails: "rails-new", runner: "runner-1", memory: "memory-1")
      bundle = build_bundle(root, "images.tar" => current_images)
      target = build_bundle(root, "images.tar" => target_images, "release/SOURCE_COMMIT" => "#{"b" * 40}\n")
      _stdout, setup_stderr, setup_status = run_setup(root, bundle)
      assert setup_status.success?, setup_stderr
      ready_upgrade(root)

      _stdout, stderr, status = run_installer(root, "upgrade", "#{root}/backup", target, "--confirm-apply",
        upgrade_docker_env(pinned_compose_services).merge(
          "DOCKER_POSTGRES_VERSION" => "160000",
          "DOCKER_FAIL_MATCH" => "up -d --wait web jobs caddy"
        ))

      assert_not status.success?
      assert_includes stderr, "restoring the previous application was unsuccessful"
      state = File.read("#{root}/var/lib/navishai/install.json")
      assert_includes state, "upgrade_app_image_unrecoverable"
      refute_includes state, "upgrade_completed"
    end
  end

  def test_application_image_load_failure_does_not_stop_the_running_install
    Dir.mktmpdir do |root|
      current_images = docker_save_images(root, rails: "rails-old", runner: "runner-1", memory: "memory-1")
      target_images = docker_save_images(root, rails: "rails-new", runner: "runner-1", memory: "memory-1")
      bundle = build_bundle(root, "images.tar" => current_images)
      target = build_bundle(root, "images.tar" => target_images, "release/SOURCE_COMMIT" => "#{"b" * 40}\n")
      _stdout, setup_stderr, setup_status = run_setup(root, bundle)
      assert setup_status.success?, setup_stderr
      current = ready_upgrade(root)

      _stdout, stderr, status = run_installer(root, "upgrade", "#{root}/backup", target, "--confirm-apply",
        upgrade_docker_env(pinned_compose_services).merge(
          "DOCKER_POSTGRES_VERSION" => "160000",
          "DOCKER_FAIL_MATCH" => "image load -i"
        ))

      assert_not status.success?
      assert_includes stderr, "could not load the target application image"
      assert_equal current, File.realpath("#{root}/opt/navishai/current")
      refute_includes docker_log(root), "stop caddy"
    end
  end

  def test_interrupted_application_image_promotion_resumes_without_repeating_promotion
    Dir.mktmpdir do |root|
      current_images = docker_save_images(root, rails: "rails-old", runner: "runner-1", memory: "memory-1")
      target_images = docker_save_images(root, rails: "rails-new", runner: "runner-1", memory: "memory-1")
      bundle = build_bundle(root, "images.tar" => current_images)
      target = build_bundle(root, "images.tar" => target_images, "release/SOURCE_COMMIT" => "#{"b" * 40}\n")
      _stdout, setup_stderr, setup_status = run_setup(root, bundle)
      assert setup_status.success?, setup_stderr
      previous = ready_upgrade(root)

      _stdout, stderr, status = run_installer(root, "upgrade", "#{root}/backup", target, "--confirm-apply",
        upgrade_docker_env(pinned_compose_services).merge(
          "DOCKER_POSTGRES_VERSION" => "160000",
          "NAVISHAI_TEST_FAIL_AFTER_APP_IMAGE_PROMOTE" => "1"
        ))

      assert_not status.success?, stderr
      assert_not_equal previous, File.realpath("#{root}/opt/navishai/current")
      assert_includes File.read("#{root}/var/lib/navishai/install.json"), "upgrade_app_image_promoted"
      assert_equal "promoted", JSON.parse(File.read("#{root}/var/lib/navishai/upgrade-attempt.json")).fetch("outcome")
      File.write("#{File.realpath("#{root}/opt/navishai/current")}/ops/compose/upgrade_preflight", "#!/bin/sh\nexit 0\n")
      FileUtils.chmod(0o755, "#{File.realpath("#{root}/opt/navishai/current")}/ops/compose/upgrade_preflight")

      File.write("#{root}/docker.log", "")
      stdout, retry_stderr, retry_status = run_installer(root, "upgrade", "#{root}/backup", target, "--confirm-apply",
        upgrade_docker_env(pinned_compose_services).merge("DOCKER_POSTGRES_VERSION" => "160000"))

      assert retry_status.success?, retry_stderr
      assert_includes File.read("#{root}/var/lib/navishai/install.json"), "upgrade_completed"
      refute_path_exists "#{root}/var/lib/navishai/upgrade-attempt.json"
      assert_equal "b" * 40, File.read("#{root}/opt/navishai/current/SOURCE_COMMIT").strip
      assert_includes stdout, "Resuming application-image upgrade"
      refute_includes docker_log(root), "db:prepare"
    end
  end

  def test_upgrade_accepts_installed_postgres_16_for_pinned_pg16_target
    Dir.mktmpdir do |root|
      bundle = build_bundle(root)
      target = build_bundle(root, "release/ops/compose/backup" => "target-backup\n")
      _stdout, setup_stderr, setup_status = run_setup(root, bundle)
      assert setup_status.success?, setup_stderr
      current = File.realpath("#{root}/opt/navishai/current")
      File.write("#{current}/ops/compose/upgrade_preflight", "#!/bin/sh\nexit 0\n")
      FileUtils.chmod(0o755, "#{current}/ops/compose/upgrade_preflight")
      File.write("#{root}/backup", "verified\n")
      File.write("#{root}/docker.log", "")

      _stdout, stderr, status = run_installer(root, "upgrade", "#{root}/backup", target, "--confirm-apply",
        "DOCKER_CONFIG_JSON" => { services: { postgres: { image: "pgvector/pgvector:0.8.6-pg16@sha256:#{'a' * 64}" } } }.to_json,
        "DOCKER_POSTGRES_VERSION" => "160000")

      assert status.success?, stderr
      assert_includes File.read("#{root}/var/lib/navishai/install.json"), "upgrade_completed"
      assert_not_equal current, File.realpath("#{root}/opt/navishai/current")
      assert_equal "target-backup\n", File.read("#{root}/opt/navishai/current/ops/compose/backup")
      log = docker_log(root)
      assert_operator log.index("stop caddy"), :<, log.index("image load")
      assert_operator log.index("run --rm web bin/rails db:prepare"), :<, log.index("up -d --wait web jobs caddy")
      refute_includes log, "up -d --wait supermemory web jobs caddy"
    end
  end

  def test_upgrade_target_start_failure_stops_every_writer_and_requires_restore
    Dir.mktmpdir do |root|
      bundle = build_bundle(root)
      target = build_bundle(root)
      _stdout, setup_stderr, setup_status = run_setup(root, bundle)
      assert setup_status.success?, setup_stderr
      current = File.realpath("#{root}/opt/navishai/current")
      File.write("#{current}/ops/compose/upgrade_preflight", "#!/bin/sh\nexit 0\n")
      FileUtils.chmod(0o755, "#{current}/ops/compose/upgrade_preflight")
      File.write("#{root}/backup", "verified\n")
      File.write("#{root}/docker.log", "")

      _stdout, stderr, status = run_installer(root, "upgrade", "#{root}/backup", target, "--confirm-apply",
        "DOCKER_CONFIG_JSON" => { services: { postgres: { image: "pgvector/pgvector:0.8.6-pg16@sha256:#{'a' * 64}" } } }.to_json,
        "DOCKER_POSTGRES_VERSION" => "160000", "DOCKER_FAIL_MATCH" => "up -d --wait postgres app-net runner")

      assert_not status.success?
      assert_includes stderr, "upgrade target_start failed"
      state = File.read("#{root}/var/lib/navishai/install.json")
      assert_includes state, "upgrade_target_start_restore_required"
      refute_includes state, "upgrade_completed"
      log = docker_log(root)
      assert_operator log.rindex("stop caddy jobs web runner supermemory"), :>, log.index("up -d --wait postgres app-net runner")
    end
  end

  def test_upgrade_image_load_failure_does_not_promote_the_target_and_stops_writers
    Dir.mktmpdir do |root|
      bundle = build_bundle(root)
      target = build_bundle(root)
      _stdout, setup_stderr, setup_status = run_setup(root, bundle)
      assert setup_status.success?, setup_stderr
      current = File.realpath("#{root}/opt/navishai/current")
      File.write("#{current}/ops/compose/upgrade_preflight", "#!/bin/sh\nexit 0\n")
      FileUtils.chmod(0o755, "#{current}/ops/compose/upgrade_preflight")
      File.write("#{root}/backup", "verified\n")
      File.write("#{root}/docker.log", "")

      _stdout, stderr, status = run_installer(root, "upgrade", "#{root}/backup", target, "--confirm-apply",
        "DOCKER_CONFIG_JSON" => { services: { postgres: { image: "pgvector/pgvector:0.8.6-pg16@sha256:#{'a' * 64}" } } }.to_json,
        "DOCKER_POSTGRES_VERSION" => "160000", "DOCKER_FAIL_MATCH" => "image load -i")

      assert_not status.success?
      assert_includes stderr, "upgrade target_load failed"
      assert_equal current, File.realpath("#{root}/opt/navishai/current")
      state = File.read("#{root}/var/lib/navishai/install.json")
      assert_includes state, "upgrade_target_load_restore_required"
      refute_includes state, "upgrade_completed"
      log = docker_log(root)
      assert_operator log.rindex("stop caddy jobs web runner supermemory"), :>, log.index("image load -i")
    end
  end

  def test_upgrade_waits_for_configured_memory_before_completion
    Dir.mktmpdir do |root|
      bundle = build_bundle(root)
      target = build_bundle(root)
      _stdout, setup_stderr, setup_status = run_setup(root, bundle)
      assert setup_status.success?, setup_stderr
      File.write("#{root}/etc/navishai/env", File.read("#{root}/etc/navishai/env").lines.reject { |line| line == "NAVISHAI_MEMORY_PENDING=1\n" }.join)
      current = File.realpath("#{root}/opt/navishai/current")
      File.write("#{current}/ops/compose/upgrade_preflight", "#!/bin/sh\nexit 0\n")
      FileUtils.chmod(0o755, "#{current}/ops/compose/upgrade_preflight")
      File.write("#{root}/backup", "verified\n")
      File.write("#{root}/docker.log", "")

      _stdout, stderr, status = run_installer(root, "upgrade", "#{root}/backup", target, "--confirm-apply",
        "DOCKER_CONFIG_JSON" => { services: { postgres: { image: "pgvector/pgvector:0.8.6-pg16@sha256:#{'a' * 64}" } } }.to_json,
        "DOCKER_POSTGRES_VERSION" => "160000")

      assert status.success?, stderr
      log = docker_log(root)
      assert_includes log, "up -d --wait supermemory web jobs caddy"
      assert_includes File.read("#{root}/var/lib/navishai/install.json"), "upgrade_completed"
    end
  end

  def test_upgrade_requires_explicit_confirmation_before_docker_or_state_mutation
    Dir.mktmpdir do |root|
      _stdout, stderr, status = run_installer(root, "upgrade", "backup", "target.tar")

      assert_not status.success?
      assert_includes stderr, "usage: navishai upgrade"
      assert_empty docker_log(root)
      refute_path_exists "#{root}/var/lib/navishai/install.json"
    end
  end

  def test_upgrade_prepare_failure_records_failure_without_app_startup
    Dir.mktmpdir do |root|
      bundle = build_bundle(root)
      target = build_bundle(root, "release/ops/compose/backup" => "target-backup\n")
      _stdout, setup_stderr, setup_status = run_setup(root, bundle)
      assert setup_status.success?, setup_stderr
      current = File.realpath("#{root}/opt/navishai/current")
      File.write("#{current}/ops/compose/upgrade_preflight", "#!/bin/sh\nexit 0\n")
      FileUtils.chmod(0o755, "#{current}/ops/compose/upgrade_preflight")
      File.write("#{root}/backup", "verified\n")
      File.write("#{root}/docker.log", "")

      _stdout, stderr, status = run_installer(root, "upgrade", "#{root}/backup", target, "--confirm-apply",
        "DOCKER_CONFIG_JSON" => { services: { postgres: { image: "pgvector/pgvector:0.8.6-pg16@sha256:#{'a' * 64}" } } }.to_json,
        "DOCKER_POSTGRES_VERSION" => "160000", "DOCKER_FAIL_MATCH" => "run --rm web bin/rails db:prepare")

      assert_not status.success?
      assert_includes stderr, "upgrade prepare failed"
      state = File.read("#{root}/var/lib/navishai/install.json")
      assert_includes state, "upgrade_prepare_restore_required"
      refute_includes state, "upgrade_completed"
      log = docker_log(root)
      refute_includes log, "up -d --wait web jobs caddy"
      assert_operator log.rindex("stop caddy jobs web runner supermemory"), :>, log.index("run --rm web bin/rails db:prepare")
    end
  end

  def test_upgrade_health_failure_records_failure_without_completion
    Dir.mktmpdir do |root|
      bundle = build_bundle(root)
      target = build_bundle(root, "release/ops/compose/backup" => "target-backup\n")
      _stdout, setup_stderr, setup_status = run_setup(root, bundle)
      assert setup_status.success?, setup_stderr
      current = File.realpath("#{root}/opt/navishai/current")
      File.write("#{current}/ops/compose/upgrade_preflight", "#!/bin/sh\nexit 0\n")
      FileUtils.chmod(0o755, "#{current}/ops/compose/upgrade_preflight")
      File.write("#{root}/backup", "verified\n")

      _stdout, stderr, status = run_installer(root, "upgrade", "#{root}/backup", target, "--confirm-apply",
        "DOCKER_CONFIG_JSON" => { services: { postgres: { image: "pgvector/pgvector:0.8.6-pg16@sha256:#{'a' * 64}" } } }.to_json,
        "DOCKER_POSTGRES_VERSION" => "160000", "DOCKER_FAIL_MATCH" => "up -d --wait web jobs caddy")

      assert_not status.success?
      assert_includes stderr, "upgrade health failed"
      state = File.read("#{root}/var/lib/navishai/install.json")
      assert_includes state, "upgrade_health_restore_required"
      refute_includes state, "upgrade_completed"
      log = docker_log(root)
      assert_operator log.rindex("stop caddy jobs web runner supermemory"), :>, log.index("up -d --wait web jobs caddy")
    end
  end

  def test_upgrade_preflight_failure_preserves_current_environment_and_tls
    Dir.mktmpdir do |root|
      bundle = build_bundle(root)
      target = build_bundle(root, "release/ops/compose/backup" => "target-backup\n")
      _stdout, setup_stderr, setup_status = run_setup(root, bundle)
      assert setup_status.success?, setup_stderr
      current = File.realpath("#{root}/opt/navishai/current")
      File.write("#{current}/ops/compose/upgrade_preflight", "#!/bin/sh\nexit 1\n")
      FileUtils.chmod(0o755, "#{current}/ops/compose/upgrade_preflight")
      File.write("#{root}/backup", "verified\n")
      environment_before = File.read("#{root}/etc/navishai/env")
      tls_before = Dir["#{root}/etc/navishai/runner/*"].to_h { |path| [ File.basename(path), Digest::SHA256.file(path).hexdigest ] }
      File.write("#{root}/docker.log", "")

      _stdout, _stderr, status = run_installer(root, "upgrade", "#{root}/backup", target, "--confirm-apply",
        "DOCKER_CONFIG_JSON" => { services: { postgres: { image: "pgvector/pgvector:0.8.6-pg16@sha256:#{'a' * 64}" } } }.to_json,
        "DOCKER_POSTGRES_VERSION" => "160000")

      assert_not status.success?
      assert_equal current, File.realpath("#{root}/opt/navishai/current")
      assert_equal environment_before, File.read("#{root}/etc/navishai/env")
      assert_equal tls_before, Dir["#{root}/etc/navishai/runner/*"].to_h { |path| [ File.basename(path), Digest::SHA256.file(path).hexdigest ] }
      refute_includes docker_log(root), "stop caddy"
      refute_includes docker_log(root), "image load"
    end
  end

  def test_failed_database_prepare_preserves_secrets_and_does_not_mark_infrastructure_started
    Dir.mktmpdir do |root|
      bundle = build_bundle(root)

      _stdout, first_stderr, first_status = run_setup(root, bundle, "DOCKER_FAIL_MATCH" => "run --rm web bin/rails db:prepare")
      assert_not first_status.success?
      env_before = File.read("#{root}/etc/navishai/env")
      tls_before = Dir["#{root}/etc/navishai/runner/*"].to_h { |path| [ File.basename(path), Digest::SHA256.file(path).hexdigest ] }
      state = File.read("#{root}/var/lib/navishai/install.json")
      assert_includes state, "secrets_ready"
      refute_includes state, "infrastructure_started"
      refute_includes docker_log(root), "up -d web jobs caddy"

      _stdout, second_stderr, second_status = run_setup(root, bundle)
      assert second_status.success?, second_stderr
      assert_equal env_before, File.read("#{root}/etc/navishai/env")
      assert_equal tls_before, Dir["#{root}/etc/navishai/runner/*"].to_h { |path| [ File.basename(path), Digest::SHA256.file(path).hexdigest ] }
    end
  end

  def test_configure_system_mail_replaces_only_system_smtp_values_from_private_references
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p("#{root}/etc/navishai")
      File.write("#{root}/etc/navishai/env", "NAVISHAI_DATABASE_PASSWORD=preserved\nNAVISHAI_SYSTEM_SMTP_ADDRESS=old.example\n")
      password = "#{root}/smtp-password"
      File.write(password, "smtp-secret")
      FileUtils.chmod(0o600, password)
      answers = "#{root}/answers"
      File.write(answers, <<~ANSWERS)
        NAVISHAI_SYSTEM_SMTP_ADDRESS=smtp.example.test
        NAVISHAI_SYSTEM_SMTP_PORT=587
        NAVISHAI_SYSTEM_SMTP_USER_NAME=mailer
        NAVISHAI_SYSTEM_SMTP_PASSWORD_FILE=#{password}
        NAVISHAI_SYSTEM_SMTP_FROM=notifications@example.test
      ANSWERS
      FileUtils.chmod(0o600, answers)

      stdout, stderr, status = run_installer(root, "configure", "system-mail", "NAVISHAI_ANSWERS_FILE" => answers)

      assert status.success?, stderr
      assert_includes stdout, "required STARTTLS"
      environment = File.read("#{root}/etc/navishai/env")
      assert_includes environment, "NAVISHAI_DATABASE_PASSWORD=preserved\n"
      assert_includes environment, "NAVISHAI_SYSTEM_SMTP_ADDRESS=smtp.example.test\n"
      assert_includes environment, "NAVISHAI_SYSTEM_SMTP_PORT=587\n"
      assert_includes environment, "NAVISHAI_SYSTEM_SMTP_USER_NAME=mailer\n"
      assert_includes environment, "NAVISHAI_SYSTEM_SMTP_PASSWORD=smtp-secret\n"
      assert_includes environment, "NAVISHAI_SYSTEM_SMTP_FROM=notifications@example.test\n"
      assert_equal 0o640, File.stat("#{root}/etc/navishai/env").mode & 0o777
      assert_includes docker_log(root), "up -d --wait web jobs"
    end
  end

  def test_configure_system_mail_rejects_invalid_input_without_changing_environment
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p("#{root}/etc/navishai")
      File.write("#{root}/etc/navishai/env", "NAVISHAI_DATABASE_PASSWORD=preserved\n")
      answers = "#{root}/answers"
      File.write(answers, "NAVISHAI_SYSTEM_SMTP_PORT=70000\n")
      FileUtils.chmod(0o600, answers)

      _stdout, stderr, status = run_installer(root, "configure", "system-mail", "NAVISHAI_ANSWERS_FILE" => answers)

      assert_not status.success?
      assert_includes stderr, "SMTP port must be between"
      assert_equal "NAVISHAI_DATABASE_PASSWORD=preserved\n", File.read("#{root}/etc/navishai/env")
      assert_empty docker_log(root)
    end
  end

  def test_configure_system_mail_rejects_an_insecure_password_reference_without_changing_environment
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p("#{root}/etc/navishai")
      File.write("#{root}/etc/navishai/env", "NAVISHAI_DATABASE_PASSWORD=preserved\n")
      password = "#{root}/smtp-password"
      File.write(password, "smtp-secret")
      FileUtils.chmod(0o644, password)
      answers = "#{root}/answers"
      File.write(answers, "NAVISHAI_SYSTEM_SMTP_PASSWORD_FILE=#{password}\n")
      FileUtils.chmod(0o600, answers)

      _stdout, stderr, status = run_installer(root, "configure", "system-mail", "NAVISHAI_ANSWERS_FILE" => answers)

      assert_not status.success?
      assert_includes stderr, "secret reference must not be readable"
      assert_equal "NAVISHAI_DATABASE_PASSWORD=preserved\n", File.read("#{root}/etc/navishai/env")
      assert_empty docker_log(root)
    end
  end

  def test_configure_system_mail_rejects_an_answer_file_owned_by_another_user_without_changing_environment
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p("#{root}/etc/navishai")
      File.write("#{root}/etc/navishai/env", "NAVISHAI_DATABASE_PASSWORD=preserved\n")
      answers = "#{root}/answers"
      File.write(answers, "NAVISHAI_SYSTEM_SMTP_ADDRESS=smtp.example.test\n")
      FileUtils.chmod(0o600, answers)

      _stdout, stderr, status = run_installer(root, "configure", "system-mail",
        "NAVISHAI_ANSWERS_FILE" => answers, "FAKE_UNOWNED_ANSWER" => answers)

      assert_not status.success?
      assert_includes stderr, "answer file must be owned"
      assert_equal "NAVISHAI_DATABASE_PASSWORD=preserved\n", File.read("#{root}/etc/navishai/env")
      assert_empty docker_log(root)
    end
  end

  def test_configure_system_mail_keeps_the_new_configuration_after_restart_failure_and_retries
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p("#{root}/etc/navishai")
      File.write("#{root}/etc/navishai/env", "NAVISHAI_DATABASE_PASSWORD=preserved\n")
      password = "#{root}/smtp-password"
      File.write(password, "smtp-secret")
      FileUtils.chmod(0o600, password)
      answers = "#{root}/answers"
      File.write(answers, <<~ANSWERS)
        NAVISHAI_SYSTEM_SMTP_ADDRESS=smtp.example.test
        NAVISHAI_SYSTEM_SMTP_PORT=587
        NAVISHAI_SYSTEM_SMTP_USER_NAME=mailer
        NAVISHAI_SYSTEM_SMTP_PASSWORD_FILE=#{password}
        NAVISHAI_SYSTEM_SMTP_FROM=notifications@example.test
      ANSWERS
      FileUtils.chmod(0o600, answers)

      _stdout, first_stderr, first_status = run_installer(root, "configure", "system-mail",
        "NAVISHAI_ANSWERS_FILE" => answers, "DOCKER_FAIL_MATCH" => "up -d --wait web jobs")

      assert_not first_status.success?
      assert_includes File.read("#{root}/etc/navishai/env"), "NAVISHAI_SYSTEM_SMTP_ADDRESS=smtp.example.test\n"

      _stdout, second_stderr, second_status = run_installer(root, "configure", "system-mail", "NAVISHAI_ANSWERS_FILE" => answers)

      assert second_status.success?, second_stderr
      assert_includes docker_log(root), "up -d --wait web jobs"
    end
  end

  def test_status_exits_successfully_and_reports_deferred_capabilities_without_secrets
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p("#{root}/etc/navishai")
      File.write("#{root}/etc/navishai/env", "NAVISHAI_DATABASE_PASSWORD=db-secret\nNAVISHAI_SUPERMEMORY_API_KEY=memory-pending-placeholder\nNAVISHAI_MEMORY_PENDING=1\n")

      stdout, stderr, pending = run_installer(root, "status")
      assert pending.success?, stderr
      assert_includes stdout, "release: none selected"
      assert_includes stdout, "memory: pending configuration"
      assert_includes stdout, "system mail: not configured"
      assert_includes stdout, "attachment scanner: not configured"
      refute_includes stdout, "db-secret"

      File.write("#{root}/etc/navishai/env", "NAVISHAI_DATABASE_PASSWORD=db-secret\nNAVISHAI_SUPERMEMORY_API_KEY=sm_private\nNAVISHAI_SYSTEM_SMTP_ADDRESS=smtp.example\nNAVISHAI_SYSTEM_SMTP_PASSWORD=mail-secret\nNAVISHAI_ATTACHMENT_SCANNER=clamd\nNAVISHAI_CLAMD_ADDRESS=tcp://scanner.internal:3310\n")

      release_id = "a" * 64
      FileUtils.mkdir_p("#{root}/opt/navishai/releases/#{release_id}")
      File.write("#{root}/opt/navishai/releases/#{release_id}/SOURCE_COMMIT", "#{'b' * 40}\n")
      File.symlink("#{root}/opt/navishai/releases/#{release_id}", "#{root}/opt/navishai/current")

      stdout, stderr, configured = run_installer(root, "status")
      assert configured.success?, stderr
      assert_includes stdout, "release: #{release_id}"
      assert_includes stdout, "source commit: #{'b' * 40}"
      assert_includes stdout, "memory: key configured"
      assert_includes stdout, "system mail: configured, untested"
      assert_includes stdout, "attachment scanner: clamd configured, untested"
      refute_includes stdout, "sm_private"
      refute_includes stdout, "mail-secret"
      assert_equal [ "compose --project-name navishai --env-file #{root}/etc/navishai/env -f #{root}/opt/navishai/current/compose.yaml -f #{root}/opt/navishai/current/ops/installer/compose.yaml ps" ] * 2, docker_log(root).lines(chomp: true)
    end
  end

  def test_doctor_reports_every_finding_with_a_recovery_action_without_repairing_anything
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p("#{root}/etc/navishai")
      FileUtils.mkdir_p("#{root}/var/lib/navishai")
      File.write("#{root}/etc/navishai/env", "NAVISHAI_APP_HOST=install.example\nNAVISHAI_PUBLIC_LISTEN_ADDRESS=203.0.113.10\nNAVISHAI_DATABASE_PASSWORD=db-secret\nNAVISHAI_MEMORY_PENDING=1\n")
      File.write("#{root}/var/lib/navishai/install.json", "{\"schema\":1,\"release\":\"pending\",\"step\":\"https_unverified\"}\n")

      stdout, stderr, status = run_installer(root, "doctor", "--json", "FAKE_PORT_80" => "LISTEN\n")

      assert_not status.success?
      assert_empty stderr
      report = JSON.parse(stdout)
      assert_equal 1, report["schema"]
      assert_equal "attention", report["result"]
      findings = report["findings"].index_by { |finding| finding["key"] }
      assert_equal "failure", findings["port_80"]["status"]
      assert_includes findings["port_80"]["message"], "port 80 is in use"
      assert_equal "failure", findings["install_step"]["status"]
      assert_includes findings["install_step"]["action"], "rerun navishai setup"
      assert_equal "failure", findings["release"]["status"]
      assert_equal "failure", findings["runner_tls"]["status"]
      assert_equal "warning", findings["memory_service"]["status"]
      assert_includes findings["memory_service"]["action"], "navishai configure memory"
      assert_equal "warning", findings["system_mail"]["status"]
      assert_equal "warning", findings["scanner"]["status"]
      refute_includes stdout, "db-secret"
      refute_match(/up -d|run --rm|image load|restart/, docker_log(root))
    end
  end

  def test_doctor_reports_healthy_text_and_exits_zero_for_a_complete_installation
    Dir.mktmpdir do |root|
      release_id = "c" * 64
      FileUtils.mkdir_p("#{root}/etc/navishai/runner")
      FileUtils.mkdir_p("#{root}/var/lib/navishai")
      FileUtils.mkdir_p("#{root}/opt/navishai/releases/#{release_id}")
      File.write("#{root}/opt/navishai/releases/#{release_id}/images.tar", "images")
      File.symlink("#{root}/opt/navishai/releases/#{release_id}", "#{root}/opt/navishai/current")
      %w[ca.crt server.crt server.key].each { |name| File.write("#{root}/etc/navishai/runner/#{name}", name) }
      File.write("#{root}/etc/navishai/env", "NAVISHAI_APP_HOST=install.example\nNAVISHAI_PUBLIC_LISTEN_ADDRESS=203.0.113.10\nNAVISHAI_SUPERMEMORY_API_KEY=sm_private\nNAVISHAI_SYSTEM_SMTP_ADDRESS=smtp.example\nNAVISHAI_ATTACHMENT_SCANNER=clamd\n")
      File.write("#{root}/var/lib/navishai/install.json", "{\"schema\":1,\"release\":\"#{'d' * 40}\",\"step\":\"https_verified\"}\n")

      stdout, stderr, status = run_installer(root, "doctor")

      assert status.success?, stderr
      assert_includes stdout, "ok: release: current release #{release_id}"
      assert_includes stdout, "ok: install_step: last recorded step: https_verified"
      assert_includes stdout, "result: healthy"
      refute_includes stdout, "sm_private"
    end
  end

  def test_doctor_tells_an_uninstalled_host_to_run_setup_and_rejects_unknown_options
    Dir.mktmpdir do |root|
      stdout, _stderr, status = run_installer(root, "doctor")

      assert_not status.success?
      assert_includes stdout, "failure: installation: NavishAI is not installed; run navishai setup CANDIDATE.tar"
      assert_includes stdout, "result: attention"

      _stdout, stderr, rejected = run_installer(root, "doctor", "--fix")
      assert_not rejected.success?
      assert_includes stderr, "usage: navishai doctor [--json]"
    end
  end

  def test_configure_memory_replaces_pending_state_and_retries_after_start_failure
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p("#{root}/etc/navishai")
      File.write("#{root}/etc/navishai/env", "NAVISHAI_DATABASE_PASSWORD=preserved\nNAVISHAI_MEMORY_PENDING=1\n")
      key = "#{root}/memory-key"
      File.write(key, "sm_private")
      FileUtils.chmod(0o600, key)
      answers = "#{root}/answers"
      File.write(answers, "NAVISHAI_SUPERMEMORY_API_KEY_FILE=#{key}\n")
      FileUtils.chmod(0o600, answers)

      _stdout, _stderr, first = run_installer(root, "configure", "memory", "NAVISHAI_ANSWERS_FILE" => answers, "DOCKER_FAIL_MATCH" => "up -d --wait supermemory web jobs")
      assert_not first.success?
      environment = File.read("#{root}/etc/navishai/env")
      assert_includes environment, "NAVISHAI_DATABASE_PASSWORD=preserved\n"
      assert_includes environment, "NAVISHAI_SUPERMEMORY_API_KEY=sm_private\n"
      refute_includes environment, "NAVISHAI_MEMORY_PENDING=1\n"

      stdout, stderr, second = run_installer(root, "configure", "memory", "NAVISHAI_ANSWERS_FILE" => answers)
      assert second.success?, stderr
      assert_includes stdout, "Confirm scoped indexing"
    end
  end

  def test_configure_scanner_preserves_environment_and_retries_after_start_failure
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p("#{root}/etc/navishai")
      File.write("#{root}/etc/navishai/env", "NAVISHAI_DATABASE_PASSWORD=preserved\n")
      answers = "#{root}/answers"
      File.write(answers, "NAVISHAI_ATTACHMENT_SCANNER=clamd\nNAVISHAI_CLAMD_ADDRESS=tcp://scanner.internal:3310\n")
      FileUtils.chmod(0o600, answers)
      _stdout, _stderr, first = run_installer(root, "configure", "scanner", "NAVISHAI_ANSWERS_FILE" => answers, "DOCKER_FAIL_MATCH" => "up -d --wait web jobs")
      assert_not first.success?
      environment = File.read("#{root}/etc/navishai/env")
      assert_includes environment, "NAVISHAI_DATABASE_PASSWORD=preserved\n"
      assert_includes environment, "NAVISHAI_ATTACHMENT_SCANNER=clamd\n"
      assert_includes environment, "NAVISHAI_CLAMD_ADDRESS=tcp://scanner.internal:3310\n"

      stdout, stderr, second = run_installer(root, "configure", "scanner", "NAVISHAI_ANSWERS_FILE" => answers)
      assert second.success?, stderr
      assert_includes stdout, "not yet reachable or tested"
      assert_includes stdout, "Files remain quarantined"
    end
  end

  def test_configure_scanner_rejects_invalid_address_without_mutating_environment
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p("#{root}/etc/navishai")
      environment_path = "#{root}/etc/navishai/env"
      File.write(environment_path, "NAVISHAI_DATABASE_PASSWORD=preserved\n")
      answers = "#{root}/answers"
      File.write(answers, "NAVISHAI_ATTACHMENT_SCANNER=clamd\nNAVISHAI_CLAMD_ADDRESS=http://scanner.internal\n")
      FileUtils.chmod(0o600, answers)

      _stdout, stderr, status = run_installer(root, "configure", "scanner", "NAVISHAI_ANSWERS_FILE" => answers)
      assert_not status.success?
      assert_includes stderr, "ClamAV address must"
      assert_equal "NAVISHAI_DATABASE_PASSWORD=preserved\n", File.read(environment_path)
      assert_empty docker_log(root)
    end
  end

  private

  def run_installer(root, *arguments)
    environment = installer_environment(root, arguments.extract_options!)
    Open3.capture3(environment, Rails.root.join("ops/installer/navishai").to_s, *arguments)
  end

  def installer_environment(root, extra_environment = {})
    bin = "#{root}/bin"
    log = "#{root}/docker.log"
    FileUtils.mkdir_p(bin)
    File.write("#{bin}/docker", <<~SH)
      #!/bin/sh
      printf '%s\n' "$*" >>"$DOCKER_TEST_LOG"
      if [ -n "${DOCKER_FAIL_MATCH:-}" ]; then
        case "$*" in
          *"$DOCKER_FAIL_MATCH"*)
            count="$(cat "${DOCKER_FAIL_COUNT_FILE:-/tmp/docker-fail-count}" 2>/dev/null || echo 0)"
            count=$((count + 1))
            printf '%s' "$count" >"${DOCKER_FAIL_COUNT_FILE:-/tmp/docker-fail-count}"
            if [ "$count" -le "${DOCKER_FAIL_TIMES:-9999}" ]; then
              exit 1
            fi
            ;;
        esac
      fi
      case "$*" in
        *"db:migrate:status"*)
          printf '%s\n' "${DOCKER_MIGRATE_STATUS:-   up      20260101000000  init}"
          ;;
        *"image load -i"*)
          for argument; do image="$argument"; done
          [ -f "$image" ] || exit 1
          ;;
        *"config --images"*)
          case "$*" in
            *"/opt/navishai/current/"*) printf '%s' "${DOCKER_CURRENT_IMAGES:-same}\n" ;;
            *) printf '%s' "${DOCKER_TARGET_IMAGES:-same}\n" ;;
          esac
          ;;
        *"config --format json"*)
          case "$*" in
            *"/opt/navishai/current/"*) printf '%s\n' "${DOCKER_CURRENT_CONFIG_JSON:-${DOCKER_CONFIG_JSON:-}}" ;;
            *) printf '%s\n' "${DOCKER_TARGET_CONFIG_JSON:-${DOCKER_CONFIG_JSON:-}}" ;;
          esac
          ;;
        *"ps --filter publish="*) printf '%s' "${FAKE_PORT_CONTAINER:-}" ;;
        *"inspect --format"*)
          case "$*" in
            *"Config.Labels"*) printf '%s' "${FAKE_PORT_LABELS:-}" ;;
            *) printf '%s' "${FAKE_PORT_BINDING:-}" ;;
          esac
          ;;
        *"SHOW server_version_num"*) printf '%s\n' "${DOCKER_POSTGRES_VERSION:-160000}" ;;
        *"info --format"*) printf '/\n' ;;
      esac
    SH
    FileUtils.chmod(0o755, "#{bin}/docker")
    File.write("#{bin}/ss", "#!/bin/sh\ncase \"$*\" in *:80*) value=\"${FAKE_PORT_80:-}\"; port=80;; *:443*) value=\"${FAKE_PORT_443:-}\"; port=443;; esac\nlistener=$(printf '%s' \"$value\")\nif [ \"$listener\" = LISTEN ]; then printf 'LISTEN 0 0 %s:%s 0.0.0.0:*\\n' \"${FAKE_LISTEN_ADDRESS:-203.0.113.10}\" \"$port\"; else printf '%s' \"$value\"; fi\n")
    FileUtils.chmod(0o755, "#{bin}/ss")
    File.write("#{bin}/ip", "#!/bin/sh\nprintf '1.1.1.1 via 203.0.113.1 dev eth0 src %s\\n' \"${FAKE_ROUTE_SOURCE:-203.0.113.10}\"\n")
    FileUtils.chmod(0o755, "#{bin}/ip")
    File.write("#{bin}/curl", <<~SH)
      #!/bin/sh
      printf '%s\\n' "$*" >>"$DOCKER_TEST_LOG"
      count="$(cat "$NAVISHAI_MANAGED_ROOT/curl-count" 2>/dev/null || echo 0)"
      count=$((count + 1))
      printf '%s' "$count" >"$NAVISHAI_MANAGED_ROOT/curl-count"
      [ "${FAKE_HTTPS_FAIL:-}" != 1 ] || exit 1
      [ "$count" -gt "${FAKE_HTTPS_FAIL_COUNT:-0}" ] || exit 1
      printf '%s' "${FAKE_HTTPS_STATUS:-200}"
    SH
    FileUtils.chmod(0o755, "#{bin}/curl")
    File.write("#{bin}/stat", <<~SH)
      #!/bin/sh
      if [ "$1" = -c ] && [ "$2" = %u ] && [ "$3" = "${FAKE_UNOWNED_ANSWER:-}" ]; then
        printf '%s\n' 65534
      else
        /usr/bin/stat "$@"
      fi
    SH
    FileUtils.chmod(0o755, "#{bin}/stat")
    File.write("#{root}/docker-fail-count", "0")
    extra_environment.merge(
      "NAVISHAI_MANAGED_ROOT" => root,
      "NAVISHAI_TEST_ALLOW_UNPRIVILEGED" => "1",
      "DOCKER_TEST_LOG" => log,
      "DOCKER_FAIL_COUNT_FILE" => "#{root}/docker-fail-count",
      "PATH" => "#{bin}:#{ENV.fetch("PATH")}"
    )
  end

  def run_setup(root, bundle, environment = {})
    answers = "#{root}/answers"
    File.write(answers, "NAVISHAI_APP_HOST=install.example\nNAVISHAI_PUBLIC_LISTEN_ADDRESS=203.0.113.10\n")
    FileUtils.chmod(0o600, answers)
    run_installer(root, "setup", bundle, { "NAVISHAI_ANSWERS_FILE" => answers, "NAVISHAI_SETUP_ACCEPT" => "yes", "NAVISHAI_HTTPS_WAIT_SECONDS" => "0" }.merge(environment))
  end

  def docker_log(root)
    path = "#{root}/docker.log"
    File.exist?(path) ? File.read(path) : ""
  end

  def restore_release(root, id, source_commit, images, marker)
    release = "#{root}/opt/navishai/releases/#{id}"
    FileUtils.mkdir_p("#{release}/ops/compose")
    File.write("#{release}/SOURCE_COMMIT", source_commit)
    File.write("#{release}/images.tar", images)
    File.write("#{release}/compose.yaml", "services: {}\n")
    FileUtils.mkdir_p("#{release}/ops/installer")
    File.write("#{release}/ops/installer/compose.yaml", "services: {}\n")
    File.write("#{release}/ops/compose/verify_backup", "#!/bin/sh\nprintf 'verify-#{marker}\\n' >>\"$RESTORE_LOG\"\n[ \"${FAKE_VERIFY_FAIL:-}\" != 1 ]\n")
    File.write("#{release}/ops/compose/restore", "#!/bin/sh\nprintf 'restore-#{marker}\\n' >>\"$RESTORE_LOG\"\n[ \"${FAKE_RESTORE_FAIL:-}\" != 1 ]\n")
    %w[verify_backup restore].each { |name| FileUtils.chmod(0o755, "#{release}/ops/compose/#{name}") }
    release
  end

  def restore_archive(root, release_id, images_sha)
    archive = "#{root}/archive"
    FileUtils.mkdir_p(archive)
    File.write("#{archive}/manifest", "managed_release_id=#{release_id}\nmanaged_images_sha256=#{images_sha}\n")
    archive
  end

  def build_bundle(root, overrides = {})
    staging = Dir.mktmpdir("bundle", root)
    files = {
      "images.tar" => "images\n",
      "release/SOURCE_COMMIT" => "#{"a" * 40}\n",
      "release/compose.yaml" => "services: {}\n",
      "release/ops/compose/backup" => "backup\n",
      "release/ops/compose/lib.sh" => "lib\n",
      "release/ops/compose/restore" => "restore\n",
      "release/ops/compose/upgrade_preflight" => "upgrade\n",
      "release/ops/compose/verify_backup" => "verify\n",
      "release/ops/installer/Caddyfile" => "caddy\n",
      "release/ops/installer/bootstrap" => "bootstrap\n",
      "release/ops/installer/compose.yaml" => "services: {}\n",
      "release/ops/installer/navishai" => "installer\n",
      "release/ops/runner/execution.example.json" => "{\"adapters\": []}\n",
      "release/script/generate_runner_tls" => "#!/bin/sh\ntouch \"$1/ca.crt\" \"$1/server.crt\" \"$1/server.key\"\n"
    }.merge(overrides)
    files.each do |path, contents|
      FileUtils.mkdir_p(File.dirname("#{staging}/#{path}"))
      File.write("#{staging}/#{path}", contents)
    end
    FileUtils.chmod(0o755, "#{staging}/release/script/generate_runner_tls")
    %w[backup restore upgrade_preflight verify_backup].each do |name|
      FileUtils.chmod(0o755, "#{staging}/release/ops/compose/#{name}")
    end
    manifest = files.keys.sort.map { |path| "#{Digest::SHA256.file("#{staging}/#{path}").hexdigest}  #{path}" }.join("\n")
    File.write("#{staging}/SHA256SUMS", "#{manifest}\n")
    bundle = "#{root}/#{SecureRandom.hex}.tar"
    system("tar", "-cf", bundle, "-C", staging, "SHA256SUMS", "images.tar", "release", exception: true)
    bundle
  ensure
    FileUtils.remove_entry(staging) if staging && File.exist?(staging)
  end

  def docker_save_images(root, rails:, runner:, memory:)
    staging = Dir.mktmpdir("save", root)
    manifest = [
      { "Config" => "#{rails}.json", "RepoTags" => [ "navishai-rails:local" ], "Layers" => [ "#{rails}-layer.tar" ] },
      { "Config" => "#{runner}.json", "RepoTags" => [ "navishai-runner:local" ], "Layers" => [ "#{runner}-layer.tar" ] },
      { "Config" => "#{memory}.json", "RepoTags" => [ "navishai-supermemory:0.0.8" ], "Layers" => [ "#{memory}-layer.tar" ] }
    ]
    File.write("#{staging}/manifest.json", JSON.generate(manifest))
    archive = "#{staging}/images.tar"
    system("tar", "-cf", archive, "-C", staging, "manifest.json", exception: true)
    File.binread(archive)
  ensure
    FileUtils.remove_entry(staging) if staging && File.exist?(staging)
  end

  def pinned_compose_services(app: "navishai-rails:local")
    postgres = "pgvector/pgvector:0.8.6-pg16@sha256:#{'a' * 64}"
    {
      services: {
        postgres: { image: postgres },
        runner: { image: "navishai-runner:local" },
        "app-net": { image: "debian:bookworm-slim@sha256:#{'b' * 64}" },
        supermemory: { image: "navishai-supermemory:0.0.8" },
        web: { image: app },
        jobs: { image: app },
        caddy: { image: "caddy:2.10.2-alpine@sha256:#{'c' * 64}" }
      }
    }
  end

  def upgrade_docker_env(services)
    payload = services.to_json
    { "DOCKER_CONFIG_JSON" => payload, "DOCKER_CURRENT_CONFIG_JSON" => payload, "DOCKER_TARGET_CONFIG_JSON" => payload }
  end

  def ready_upgrade(root)
    current = File.realpath("#{root}/opt/navishai/current")
    File.write("#{current}/ops/compose/upgrade_preflight", "#!/bin/sh\nexit 0\n")
    FileUtils.chmod(0o755, "#{current}/ops/compose/upgrade_preflight")
    File.write("#{root}/backup", "verified\n")
    File.write("#{root}/docker.log", "")
    current
  end

  def runner_tls_digests(root)
    Dir["#{root}/etc/navishai/runner/*"].to_h { |path| [ File.basename(path), Digest::SHA256.file(path).hexdigest ] }
  end
end
