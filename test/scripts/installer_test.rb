require "test_helper"
require "open3"
require "tmpdir"
require "fileutils"
require "shellwords"
require "json"

class InstallerTest < ActiveSupport::TestCase
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
      File.write(answers, "NAVISHAI_APP_HOST=install.example\n")
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
      File.write(answers, "NAVISHAI_APP_HOST=Install.Example.\n")
      FileUtils.chmod(0o600, answers)

      _stdout, stderr, status = run_installer(root, "setup", bundle,
        "NAVISHAI_ANSWERS_FILE" => answers, "NAVISHAI_SETUP_ACCEPT" => "yes")

      assert status.success?, stderr
      assert_includes File.read("#{root}/etc/navishai/env"), "NAVISHAI_APP_HOST=install.example"
    end
  end

  def test_answer_file_setup_does_not_emit_the_actual_token_under_a_pty
    Dir.mktmpdir do |root|
      bundle = build_bundle(root)
      answers = "#{root}/answers"
      transcript = "#{root}/setup.typescript"
      File.write(answers, "NAVISHAI_APP_HOST=install.example\n")
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
          *"$DOCKER_FAIL_MATCH"*) exit 1 ;;
        esac
      fi
      case "$*" in
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
    File.write("#{bin}/ss", "#!/bin/sh\ncase \"$*\" in *:80*) printf '%s' \"${FAKE_PORT_80:-}\";; *:443*) printf '%s' \"${FAKE_PORT_443:-}\";; esac\n")
    FileUtils.chmod(0o755, "#{bin}/ss")
    File.write("#{bin}/curl", "#!/bin/sh\nprintf '%s\\n' \"$*\" >>\"$DOCKER_TEST_LOG\"\n[ \"${FAKE_HTTPS_FAIL:-}\" != 1 ] || exit 1\nprintf '%s' \"${FAKE_HTTPS_STATUS:-200}\"\n")
    FileUtils.chmod(0o755, "#{bin}/curl")
    extra_environment.merge(
      "NAVISHAI_MANAGED_ROOT" => root,
      "NAVISHAI_TEST_ALLOW_UNPRIVILEGED" => "1",
      "DOCKER_TEST_LOG" => log,
      "PATH" => "#{bin}:#{ENV.fetch("PATH")}"
    )
  end

  def run_setup(root, bundle, environment = {})
    answers = "#{root}/answers"
    File.write(answers, "NAVISHAI_APP_HOST=install.example\n")
    FileUtils.chmod(0o600, answers)
    run_installer(root, "setup", bundle, { "NAVISHAI_ANSWERS_FILE" => answers, "NAVISHAI_SETUP_ACCEPT" => "yes" }.merge(environment))
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
    manifest = files.keys.sort.map { |path| "#{Digest::SHA256.file("#{staging}/#{path}").hexdigest}  #{path}" }.join("\n")
    File.write("#{staging}/SHA256SUMS", "#{manifest}\n")
    bundle = "#{root}/#{SecureRandom.hex}.tar"
    system("tar", "-cf", bundle, "-C", staging, "SHA256SUMS", "images.tar", "release", exception: true)
    bundle
  ensure
    FileUtils.remove_entry(staging) if staging && File.exist?(staging)
  end
end
