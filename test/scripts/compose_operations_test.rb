require "test_helper"
require "fileutils"
require "open3"
require "tmpdir"

class ComposeOperationsTest < ActiveSupport::TestCase
  setup do
    @temporary = Dir.mktmpdir("compose-operations")
    @bin = File.join(@temporary, "bin")
    @log = File.join(@temporary, "docker.log")
    FileUtils.mkdir_p(@bin)
    File.write(File.join(@bin, "docker"), <<~SH)
      #!/bin/sh
      set -eu
      printf '%s\n' "$*" >>"$FAKE_DOCKER_LOG"
      case "$*" in
        *"pg_dump"*) printf 'fake pg dump' ;;
        *"--entrypoint tar"*) tar -cf - --files-from /dev/null ;;
        *"config --images"*) printf 'navishai-rails:test\nnavishai-runner:test\npgvector/pgvector:0.8.6-pg15@sha256:test\n' ;;
        *"SHOW server_version_num"*) printf '150014\n' ;;
        *"SELECT extversion"*) printf '0.8.6\n' ;;
        *"pg_restore --list"*|*"pg_restore --username"*|*"--entrypoint sh"*) cat >/dev/null ;;
      esac
    SH
    FileUtils.chmod(0o755, File.join(@bin, "docker"))
  end

  teardown do
    FileUtils.rm_rf(@temporary)
  end

  test "creates and verifies a complete quiesced backup" do
    archive = File.join(@temporary, "backup")

    stdout, stderr, status = run_operation("backup", archive)

    assert status.success?, stderr
    assert_includes stdout, "Backup written"
    assert_equal %w[
      SHA256SUMS environment-keys.txt images.txt manifest navishai_production.dump
      navishai_production_cable.dump navishai_production_cache.dump navishai_production_queue.dump
      rails-storage.tar runner-state.tar supermemory-state.tar
    ], Dir.children(archive).sort
    commands = File.readlines(@log, chomp: true)
    stop_index = commands.index { |command| command.include?("stop jobs web runner") }
    dump_index = commands.index { |command| command.include?("pg_dump") }
    assert_operator stop_index, :<, dump_index
    assert commands.any? { |command| command.include?("stop supermemory") }

    _stdout, verify_stderr, verify_status = run_operation("verify_backup", archive)
    assert verify_status.success?, verify_stderr

    File.write(File.join(archive, "images.txt"), "tampered")
    _stdout, _stderr, tampered_status = run_operation("verify_backup", archive)
    assert_not tampered_status.success?
  end

  test "restore requires confirmation and restores every state group" do
    archive = File.join(@temporary, "backup")
    _stdout, stderr, backup_status = run_operation("backup", archive)
    assert backup_status.success?, stderr

    _stdout, _stderr, refused_status = run_operation("restore", archive)
    assert_not refused_status.success?

    _stdout, restore_stderr, restore_status = run_operation("restore", archive, "--confirm-destroy")
    assert restore_status.success?, restore_stderr
    commands = File.readlines(@log, chomp: true)
    assert_equal 4, commands.count { |command| command.include?("dropdb") }
    assert_equal 4, commands.count { |command| command.include?("pg_restore --username") }
    assert_equal 3, commands.count { |command| command.include?("--entrypoint sh") }
  end

  test "upgrade preflight binds a verified backup to supported infrastructure" do
    archive = File.join(@temporary, "backup")
    certs = File.join(@temporary, "runner-certs")
    _stdout, stderr, backup_status = run_operation("backup", archive)
    assert backup_status.success?, stderr
    assert system(Rails.root.join("script/generate_runner_tls").to_s, certs, out: File::NULL)

    stdout, preflight_stderr, preflight_status = run_operation(
      "upgrade_preflight", archive, "NAVISHAI_RUNNER_CERTS_PATH" => certs
    )

    assert preflight_status.success?, preflight_stderr
    assert_includes stdout, "Upgrade preflight passed"
    assert File.readlines(@log).any? { |command| command.include?("db:migrate:status") }
  end

  private

  def run_operation(name, *arguments)
    extra_environment = arguments.extract_options!
    environment = {
      "PATH" => "#{@bin}:#{ENV.fetch("PATH")}",
      "FAKE_DOCKER_LOG" => @log
    }.merge(extra_environment)
    Open3.capture3(environment, Rails.root.join("ops/compose/#{name}").to_s, *arguments)
  end
end
