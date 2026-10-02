require "minitest/autorun"
require "fileutils"
require "json"
require "open3"
require "shellwords"
require "tmpdir"

class VpsCliTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  SHA = "a" * 40

  def setup
    @directory = Dir.mktmpdir("navishai-vps-cli-test-")
    FileUtils.chmod(0755, @directory)
    @root = "#{@directory}/managed"
    @prefix = "#{@root}/opt/navishai-reset"
    @config = "#{@root}/etc/navishai-reset"
    @state = "#{@root}/var/lib/navishai-reset"
    @release = "#{@prefix}/releases/#{SHA}"
    @units = "#{@root}/etc/systemd/system"
    FileUtils.mkdir_p([ @release, @config, @state, @units, "#{@root}/usr/local/bin" ])
    File.write("#{@release}/SOURCE_COMMIT", "#{SHA}\n")
    FileUtils.mkdir_p("#{@release}/bin")
    File.write("#{@release}/bin/navishai-vps", "# inert test release\n")
    File.symlink("releases/#{SHA}", "#{@prefix}/current")
    File.symlink("#{@prefix}/current/bin/navishai-vps", "#{@root}/usr/local/bin/navishai-reset")
    File.write("#{@state}/install.json", JSON.generate(schema: 1, project: "navishai-reset", prefix: @prefix, config: @config, state: @state, commit: SHA), perm: 0600)
    @env = {
      "NAVISHAI_APP_HOST" => "support.example.test", "NAVISHAI_ACME_EMAIL" => "owner@example.test",
      "NAVISHAI_DATABASE_PASSWORD" => "a" * 48, "NAVISHAI_POSTGRES_PASSWORD" => "b" * 48,
      "NAVISHAI_PREPARE_PASSWORD" => "c" * 48, "NAVISHAI_SECRET_KEY_BASE" => "d" * 96,
      "NAVISHAI_SYSTEM_SMTP_ADDRESS" => "smtp.example.test", "NAVISHAI_SYSTEM_SMTP_PORT" => "587",
      "NAVISHAI_SYSTEM_SMTP_USER_NAME" => "owner", "NAVISHAI_SYSTEM_SMTP_PASSWORD" => "test-only",
      "NAVISHAI_SYSTEM_SMTP_FROM" => "Owner <owner@example.test>"
    }
    write_env
    %w[navishai-reset.service navishai-reset-check.service navishai-reset-check.timer].each do |unit|
      File.write("#{@units}/#{unit}", "ExecStart=#{@root}/usr/local/bin/navishai-reset --root #{@root} #{unit.include?('check') ? 'check' : 'start'}\n")
    end
    @containers = [ container("1", "web"), container("2", "postgres"), { id: "3" * 64, labels: { "com.docker.compose.project" => "unrelated" }, mounts: [] } ]
    @volumes = [ { Name: "navishai-reset_rails_storage", Driver: "local", Options: {}, Labels: { "com.navishai.owner" => "navishai-reset", "com.docker.compose.project" => "navishai-reset", "com.docker.compose.volume" => "rails_storage" } } ]
    @networks = [ { Id: "4" * 64, Name: "navishai-reset_control", Labels: { "com.navishai.owner" => "navishai-reset", "com.docker.compose.project" => "navishai-reset", "com.docker.compose.network" => "control" }, Containers: { "1" * 64 => {}, "2" * 64 => {} } } ]
    File.write("#{@directory}/mutations", "")
    freeze_files
  end

  def teardown
    root_command("rm", "-rf", "--", @directory) if @directory
  end

  def test_managed_root_refuses_writable_ancestry_before_any_command
    root_command("chmod", "0777", @root)
    output, status = shell("echo MUST-NOT-RUN")
    refute status.success?, output
    assert_includes output, "Directory ancestry is not root-controlled"
    refute_includes output, "MUST-NOT-RUN"
    assert File.exist?("#{@config}/env")
  end

  def test_literal_env_never_runs_shell_and_clears_old_exports
    @env["NAVISHAI_SYSTEM_SMTP_PASSWORD"] = "$(touch #{@directory}/executed)"
    write_env
    freeze_files
    output, status = shell('export NAVISHAI_MATCHING_ENDPOINTS=old; vps_load_env; printf "%s\n%s\n" "$NAVISHAI_SYSTEM_SMTP_PASSWORD" "$NAVISHAI_MATCHING_ENDPOINTS"')
    assert status.success?, output
    assert_equal "$(touch #{@directory}/executed)\n[]\n", output
    refute File.exist?("#{@directory}/executed")
    refute_includes output, "a" * 48
  end

  def test_env_refuses_shell_statements_unknown_keys_duplicate_keys_and_shared_secrets
    [ "source /root/private\n", "RAILS_ENV=development\n", "NAVISHAI_APP_HOST='other.test'\n" ].each do |suffix|
      write_env(suffix)
      freeze_files
      output, status = shell("vps_load_env")
      refute status.success?, output
    end
    @env["NAVISHAI_PREPARE_PASSWORD"] = @env.fetch("NAVISHAI_DATABASE_PASSWORD")
    write_env
    freeze_files
    output, status = shell("vps_load_env")
    refute status.success?, output
    assert_includes output, "must differ"
  end

  def test_env_refuses_public_permissions_and_hardlinks
    root_command("chmod", "0644", "#{@config}/env")
    output, status = shell("vps_load_env")
    refute status.success?, output
    root_command("chmod", "0600", "#{@config}/env")
    root_command("ln", "#{@config}/env", "#{@directory}/shared-env")
    output, status = shell("vps_load_env")
    refute status.success?, output
  end

  def test_compose_uses_dynamic_release_and_only_validated_final_image_overlay
    overlay = { services: %w[app-net jobs postgres proxy web].to_h { |s| [ s, { image: "sha256:#{'9' * 64}" } ] } }
    write_private("#{@state}/recovery-images.yaml", JSON.generate(overlay))
    freeze_files
    output, status = shell('vps_docker() { printf "%s\n" "$@"; }; vps_compose ps')
    assert status.success?, output
    assert_equal [ "compose", "--project-name", "navishai-reset", "--project-directory", @release, "--env-file", "#{@config}/env", "--file", "#{@release}/compose.yaml", "--file", "#{@release}/ops/vps/compose.yaml", "--file", "#{@state}/recovery-images.yaml", "ps" ], output.lines.map(&:strip)
    overlay[:services]["web"][:privileged] = true
    root_command("rm", "#{@state}/recovery-images.yaml")
    write_private("#{@state}/recovery-images.yaml", JSON.generate(overlay))
    freeze_files
    output, status = shell("vps_docker() { echo MUST-NOT-RUN; }; vps_compose ps")
    refute status.success?, output
    refute_includes output, "MUST-NOT-RUN"
  end

  def test_start_stops_writers_then_checks_both_guards_before_maintenance_or_start
    script = <<~'SH'
      NAVISHAI_APP_HOST=support.example.test
      vps_stop() { echo STOP; }
      vps_compose() { printf 'COMPOSE %s\n' "$*"; }
      vps_policy_apply() { echo APPLY; }
      vps_policy_check() { echo CHECK; }
      vps_validate() { echo VALIDATE; }
      vps_runtime_check() { echo RUNTIME; }
      vps_https() { echo TLS; }
      curl() { echo HEALTH; }
      vps_receipt() { echo READY; }
      vps_start
    SH
    output, status = shell(script)
    assert status.success?, output
    assert_equal [ "STOP", "COMPOSE up -d --no-deps --wait postgres", "COMPOSE up -d --no-deps --force-recreate --wait app-net", "APPLY", "CHECK", "VALIDATE", "COMPOSE create --no-deps --force-recreate web jobs", "RUNTIME", "CHECK", "COMPOSE start web jobs", "CHECK", "COMPOSE up -d --no-deps proxy", "TLS", "READY" ], output.lines.map(&:strip)
    output, status = shell(script.sub("echo CHECK;", "echo CHECK; return 7;"))
    refute status.success?, output
    refute_includes output, "VALIDATE"
    refute_includes output, "web jobs"
    assert_equal 2, output.lines.count { |line| line.strip == "STOP" }
    output, status = shell(script.sub("echo TLS;", "return 7;").sub("vps_start\n", "sleep() { :; }; vps_start\n"))
    refute status.success?, output
    refute_includes output, "READY"
    assert_includes output, "Verified local HTTPS failed"
  end

  def test_runtime_check_refuses_old_namespace_elevated_flags_and_preparation_secrets
    metadata = { user: "1000:1000", labels: { "com.navishai.owner" => "navishai-reset", "com.docker.compose.project" => "navishai-reset", "com.docker.compose.service" => "web" }, env: [ "NAVISHAI_DATABASE_PASSWORD=test-runtime" ], host: { NetworkMode: "container:#{'1' * 64}", Privileged: false, RestartPolicy: { Name: "no" }, CapDrop: [ "ALL" ], CapAdd: [], SecurityOpt: [ "no-new-privileges:true" ] } }
    run = lambda do |record|
      shell(<<~SH)
        vps_compose() { if [[ $* == *app-net ]]; then echo #{'1' * 64}; else echo #{'2' * 64}; fi; }
        vps_docker() { cat <<'JSON' | jq --arg service web '.labels["com.docker.compose.service"] = $service'
        #{JSON.generate(record)}
        JSON
        }
        # One service success followed by jobs label mismatch proves web passed.
        vps_runtime_check
      SH
    end
    output, status = run.call(metadata)
    refute status.success?, output
    assert_includes output, "jobs"
    [ ->(r) { r[:host][:NetworkMode] = "container:#{'9' * 64}" }, ->(r) { r[:host][:Privileged] = true }, ->(r) { r[:env] << "NAVISHAI_PREPARE_PASSWORD=must-not-print" } ].each do |change|
      record = Marshal.load(Marshal.dump(metadata))
      change.call(record)
      output, status = run.call(record)
      refute status.success?, output
      assert_includes output, "web"
      refute_includes output, "must-not-print"
    end
  end

  def test_upgrade_failure_restores_full_point_and_never_restarts_rollback_writers
    script = <<~'SH'
      source=reviewed; commit=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb; backup=point
      vps_archive() { echo ARCHIVE; }
      vps_backup() { echo BACKUP; }
      vps_candidate() { echo CANDIDATE; return 7; }
      vps_stop() { echo STOP; }
      vps_restore() { echo RESTORE; }
      vps_load_env() { echo RELOAD; }
      vps_start() { echo MUST-NOT-START; }
      vps_upgrade
    SH
    output, status = shell(script)
    refute status.success?, output
    assert_match(/BACKUP\nCANDIDATE\nSTOP\nRESTORE\nRELOAD\n/, output)
    assert_includes output, "writers stopped"
    refute_includes output, "MUST-NOT-START"
    output, status = shell(script.sub("echo BACKUP;", "echo BACKUP; return 7;"))
    refute status.success?, output
    refute_includes output, "CANDIDATE"
    refute_includes output, "RESTORE"
  end

  def test_cleanup_preview_is_read_only_and_apply_removes_only_verified_resources
    output, status = cleanup
    assert status.success?, output
    assert_includes output, "PREVIEW ONLY"
    assert_empty mutations
    refute_includes output, "test-only"
    digest = output[/Plan SHA256: ([0-9a-f]{64})/, 1]
    output, status = cleanup("true", digest)
    assert status.success?, output
    refute File.exist?(@prefix)
    assert_includes mutations, "docker rm #{'1' * 64} #{'2' * 64}"
    refute_includes mutations, "3" * 64
    refute_includes mutations, "prune"
  end

  def test_cleanup_refuses_shared_volume_bind_and_network_before_stopping_anything
    @containers.last[:mounts] = [ { Type: "volume", Name: "navishai-reset_rails_storage" } ]
    output, status = cleanup
    refute status.success?, output
    assert_includes output, "Shared volume"
    assert_empty mutations
    @containers.last[:mounts] = [ { Type: "bind", Source: @root } ]
    output, status = cleanup
    refute status.success?, output
    assert_includes output, "shares a managed bind"
    assert_empty mutations
    @containers.last[:mounts] = []
    @networks.first[:Containers]["3" * 64] = {}
    output, status = cleanup
    refute status.success?, output
    assert_empty mutations
  end

  def test_install_refuses_unlabelled_named_volumes_and_inventory_failure
    root_command("mkdir", "#{@directory}/fresh")
    script = <<~SH
      vps_paths #{Shellwords.escape("#{@directory}/fresh")}
      source=reviewed; commit=#{SHA}; envfile=#{Shellwords.escape("#{@config}/env")}
      vps_docker() { [[ $1 != volume ]] || echo navishai-reset_lab_postgres_data; }
      vps_install
    SH
    output, status = shell(script)
    refute status.success?, output
    assert_includes output, "even without labels"
    refute File.exist?("#{@directory}/fresh/opt/navishai-reset")
    output, status = shell(script.sub("[[ $1 != volume ]] || echo navishai-reset_lab_postgres_data;", "return 7;"))
    refute status.success?, output
    refute File.exist?("#{@directory}/fresh/opt/navishai-reset")
  end

  def test_failed_pre_docker_install_removes_only_its_new_staging_roots
    root_command("mkdir", "#{@directory}/fresh")
    output, status = shell(<<~SH)
      vps_paths #{Shellwords.escape("#{@directory}/fresh")}
      source=reviewed; commit=#{SHA}; envfile=#{Shellwords.escape("#{@config}/env")}
      vps_docker() { :; }
      vps_archive() { mkdir -p "$VPS_PREFIX/releases"; return 7; }
      vps_install
    SH
    refute status.success?, output
    %w[opt/navishai-reset etc/navishai-reset var/lib/navishai-reset].each do |path|
      refute File.exist?("#{@directory}/fresh/#{path}")
    end
    assert File.exist?("#{@config}/env")
    assert File.exist?(@release)
  end

  def test_partial_install_cleanup_requires_receipt_and_not_env_or_missing_units
    root_command("rm", "-f", "#{@root}/usr/local/bin/navishai-reset", "#{@config}/env",
      *%w[navishai-reset.service navishai-reset-check.service navishai-reset-check.timer].map { |name| "#{@units}/#{name}" })
    output, status = cleanup
    refute status.success?, output
    assert_empty mutations
    output, status = shell("vps_receipt #{SHA} installing; vps_load cleanup")
    assert status.success?, output
    output, status = cleanup
    assert status.success?, output
    digest = output[/Plan SHA256: ([0-9a-f]{64})/, 1]
    output, status = cleanup("true", digest)
    assert status.success?, output
    refute File.exist?(@prefix)
    refute_includes mutations, "systemctl disable"
  end

  def test_init_env_writes_private_distinct_secrets_and_refuses_overwrite
    output, status = shell("host=support.example.test; email=owner@example.test; output=#{Shellwords.escape("#{@directory}/new.env")}; vps_init_env; stat -c '%u:%a' \"$output\"")
    assert status.success?, output
    assert_includes output, "0:600"
    refute_match(/[0-9a-f]{96}/, output)
    values = root_command("cat", "#{@directory}/new.env").scan(/^NAVISHAI_(?:DATABASE|POSTGRES|PREPARE)_PASSWORD='([0-9a-f]{96})'$/).flatten
    assert_equal 3, values.length
    assert_equal 3, values.uniq.length
    output, status = shell("host=support.example.test; email=owner@example.test; output=#{Shellwords.escape("#{@directory}/new.env")}; vps_init_env")
    refute status.success?, output
    output, status = shell("host='unsafe{host}'; email=owner@example.test; output=#{Shellwords.escape("#{@directory}/unsafe.env")}; vps_init_env")
    refute status.success?, output
    refute File.exist?("#{@directory}/unsafe.env")
  end

  def test_cleanup_changed_plan_and_stop_failure_keep_files_and_data
    output, status = cleanup
    assert status.success?, output
    digest = output[/Plan SHA256: ([0-9a-f]{64})/, 1]
    @volumes.first[:CreatedAt] = "changed"
    output, status = cleanup("true", digest)
    refute status.success?, output
    assert_empty mutations
    assert File.exist?(@prefix)
    output, status = cleanup
    assert status.success?, output
    digest = output[/Plan SHA256: ([0-9a-f]{64})/, 1]
    output, status = cleanup("true", digest, stop_failure: true)
    refute status.success?, output
    assert File.exist?(@prefix)
    refute_includes mutations, "volume rm"
    refute_includes mutations, "docker rm"
  end

  private

  def write_env(suffix = "")
    # Existing files become root-owned; replace via root rather than chmod them open.
    root_command("rm", "-f", "#{@config}/env")
    write_private("#{@config}/env", @env.map { |k, v| "#{k}='#{v}'\n" }.join + suffix)
  end

  def write_private(path, body)
    command = Process.uid.zero? ? [] : [ "sudo", "-n" ]
    output, status = Open3.capture2e(*command, "tee", path, stdin_data: body)
    raise output unless status.success?
    root_command("chmod", "0600", path)
  end

  def freeze_files
    root_command("chown", "-R", "root:root", @directory)
  end

  def root_command(*args)
    args = [ "sudo", "-n", *args ] unless Process.uid.zero?
    output, status = Open3.capture2e(*args)
    raise output unless status.success?
    output
  end

  def shell(script)
    root_command_args = Process.uid.zero? ? [] : [ "sudo", "-n" ]
    Open3.capture2e(*root_command_args, "bash", "-euo", "pipefail", "-c", "source ops/vps/cli.sh; vps_paths #{Shellwords.escape(@root)}; VPS_RELEASE=#{Shellwords.escape(@release)}; #{script}", chdir: ROOT)
  end

  def container(char, service)
    { id: char * 64, labels: { "com.navishai.owner" => "navishai-reset", "com.docker.compose.project" => "navishai-reset", "com.docker.compose.service" => service, "com.docker.compose.project.config_files" => "#{@release}/compose.yaml,#{@release}/ops/vps/compose.yaml" }, mounts: [] }
  end

  def mutations
    File.read("#{@directory}/mutations")
  end

  def cleanup(apply = "false", digest = "", stop_failure: false)
    shell(<<~SH)
      vps_container_inventory() { cat <<'JSON'
      #{JSON.generate(@containers)}
      JSON
      }
      vps_docker() {
        case "$1 $2" in
          'volume ls') echo navishai-reset_rails_storage ;;
          'volume inspect') cat <<'JSON'
      #{JSON.generate(@volumes)}
      JSON
      ;;
          'network ls') echo #{'4' * 64} ;;
          'network inspect') cat <<'JSON'
      #{JSON.generate(@networks)}
      JSON
      ;;
          *) echo "docker $*" >> #{Shellwords.escape("#{@directory}/mutations")}; #{stop_failure ? '[[ $1 != stop ]]' : 'true'} ;;
        esac
      }
      findmnt() { echo '{"filesystems":[{"target":"/"}]}'; }
      systemctl() { echo "systemctl $*" >> #{Shellwords.escape("#{@directory}/mutations")}; }
      vps_cleanup #{apply} #{Shellwords.escape(digest)}
    SH
  end
end
