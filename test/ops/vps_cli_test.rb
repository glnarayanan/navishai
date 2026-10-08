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
    File.symlink("#{@prefix}/current/bin/navishai-vps", "#{@root}/usr/local/bin/navishai")
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
      File.write("#{@units}/#{unit}", "ExecStart=#{@root}/usr/local/bin/navishai --root #{@root} #{unit.include?('check') ? 'check' : 'start'}\n")
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

  def test_generated_startup_files_refuse_writable_unit_directory
    root_command("rm", "-f", "#{@root}/usr/local/bin/navishai",
      *%w[navishai-reset.service navishai-reset-check.service navishai-reset-check.timer].map { |name| "#{@units}/#{name}" })
    root_command("chmod", "0777", @units)
    output, status = shell("systemctl() { echo MUST-NOT-RUN; }; vps_units")
    refute status.success?, output
    assert_includes output, "Directory ancestry is not root-controlled"
    refute_includes output, "MUST-NOT-RUN"
    refute File.exist?("#{@units}/navishai-reset.service")
    refute File.symlink?("#{@root}/usr/local/bin/navishai")
  end

  def test_real_root_git_archive_normalizes_modes_and_is_recoverable
    output, status = shell(<<~SH)
      fixture=#{Shellwords.escape("#{@directory}/source")}
      mkdir -p "$fixture/bin" "$fixture/ops/vps" "$fixture/raw"
      for file in bin/navishai-vps ops/vps/cli.sh ops/vps/compose.yaml ops/vps/policy.sh ops/vps/recovery.sh ops/vps/initialize_roles.sh Gemfile; do
        printf 'archive fixture\n' > "$fixture/$file"
      done
      chmod 755 "$fixture/bin/navishai-vps"
      git -C "$fixture" init -q
      git -C "$fixture" config user.name 'Archive fixture'
      git -C "$fixture" config user.email 'fixture@example.invalid'
      git -C "$fixture" config tar.umask 0002
      git -C "$fixture" add .
      git -C "$fixture" commit -qm fixture
      sha=$(git -C "$fixture" rev-parse HEAD)
      git -C "$fixture" archive "$sha" | tar -x -C "$fixture/raw"
      [[ $(stat -c %a "$fixture/raw/Gemfile") == 664 ]]
      vps_archive "$fixture" "$sha" >/dev/null
      release="$VPS_PREFIX/releases/$sha"
      printf '%s\n' "$(stat -c %a "$release/Gemfile")" "$(stat -c %a "$release/bin/navishai-vps")" "$(stat -c %a "$release/ops")"
      source ops/vps/recovery.sh
      tar --format=ustar --hard-dereference -cf #{Shellwords.escape("#{@directory}/release.tar")} -C "$release" .
      vps_recovery_tar_check #{Shellwords.escape("#{@directory}/release.tar")} root
    SH
    assert status.success?, output
    assert_equal "644\n755\n755\n", output
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

  def test_public_listen_address_refuses_private_tailnet_and_invalid_literals
    output, status = shell("vps_public_listen_address 203.0.113.9")
    assert status.success?, output
    %w[0.0.0.0 127.0.0.1 10.0.0.1 172.16.0.1 192.168.0.1 169.254.0.1 100.64.0.1 100.98.160.115 100.127.255.254 224.0.0.1 256.0.0.1 203.0.113.9:443 203.0.113.009].each do |address|
      output, status = shell("vps_public_listen_address #{Shellwords.escape(address)}")
      refute status.success?, "#{address}: #{output}"
    end
    output, status = shell("ip() { return 7; }; vps_resolve_ingress")
    refute status.success?, output
  end

  def test_auto_ingress_rederives_destination_and_refuses_ambiguity_and_stale_override
    output, status = shell('VPS_PUBLIC_LISTEN_ADDRESS=198.51.100.99; vps_resolve_ingress; echo "$VPS_PUBLIC_LISTEN_ADDRESS"')
    assert status.success?, output
    assert_equal "203.0.113.9\n", output
    output, status = shell(host_network("198.51.100.23") + 'vps_resolve_ingress; echo "$VPS_PUBLIC_LISTEN_ADDRESS"')
    assert status.success?, output
    assert_equal "198.51.100.23\n", output
    output, status = shell(host_network("203.0.113.9", "198.51.100.23") + "vps_resolve_ingress")
    refute status.success?, output
    assert_includes output, "No safe unique choice"
    output, status = shell(host_network("203.0.113.9", "198.51.100.23") + 'vps_resolve_ingress 198.51.100.23; echo "$VPS_PUBLIC_LISTEN_ADDRESS"')
    assert status.success?, output
    assert_equal "198.51.100.23\n", output
    output, status = shell("vps_resolve_ingress 198.51.100.23")
    refute status.success?, output
    output, status = shell(host_network("100.98.160.115") + "vps_resolve_ingress")
    refute status.success?, output
  end

  def test_check_refuses_stale_proxy_binding_and_stops_writers
    bindings = { "80/tcp" => [ { HostIp: "198.51.100.99", HostPort: "80" } ], "443/tcp" => [ { HostIp: "198.51.100.99", HostPort: "443" }, { HostIp: "127.0.0.1", HostPort: "443" } ] }
    script = <<~SH
      vps_policy_check() { :; }; vps_runtime_check() { :; }; vps_services_check() { :; }
      vps_compose() { echo #{'c' * 64}; }
      vps_docker() { printf '%s' #{Shellwords.escape(JSON.generate(bindings))}; }
      vps_stop() { echo STOPPED; }
      vps_check
    SH
    output, status = shell(script)
    refute status.success?, output
    assert_includes output, "stale or unsafe"
    assert_includes output, "STOPPED"
    output, status = shell(script.gsub("198.51.100.99", "203.0.113.9"))
    assert status.success?, output
    refute_includes output, "STOPPED"
  end

  def test_dns_gate_checks_public_resolution_without_assuming_proxy_origin_address
    output, status = shell("NAVISHAI_APP_HOST=lab.example.com; getent() { echo '104.16.1.2 STREAM lab.example.com'; }; vps_dns_check")
    assert status.success?, output
    %w[127.0.0.1 100.98.160.115 10.0.0.1].each do |address|
      output, status = shell("NAVISHAI_APP_HOST=lab.example.com; getent() { echo '#{address} STREAM lab.example.com'; }; vps_dns_check")
      refute status.success?, output
    end
    output, status = shell("NAVISHAI_APP_HOST=lab.example.com; getent() { return 7; }; vps_dns_check")
    refute status.success?, output
  end

  def test_ingress_check_preserves_tailnet_listeners_but_refuses_endpoint_conflicts
    listeners = "LISTEN 0 4096 100.98.160.115:443 0.0.0.0:*\nLISTEN 0 4096 [fd7a:115c:a1e0::6634:a074]:443 [::]:*\nLISTEN 0 4096 127.0.0.1:80 0.0.0.0:*\n"
    script = <<~SH
      NAVISHAI_PUBLIC_LISTEN_ADDRESS=203.0.113.9
      ss() { printf '%s' #{Shellwords.escape(listeners)}; }
      vps_ingress_check
    SH
    output, status = shell(script)
    assert status.success?, output
    %w[203.0.113.9:80 203.0.113.9:443 127.0.0.1:443 0.0.0.0:80 0.0.0.0:443 *:443 [::]:80 [::]:443].each do |endpoint|
      output, status = shell(script.sub(Shellwords.escape(listeners), Shellwords.escape("#{listeners}LISTEN 0 4096 #{endpoint} *:*\n")))
      refute status.success?, "#{endpoint}: #{output}"
      assert_includes output, "Ingress endpoint in use"
    end
    output, status = shell(script.sub("ss() { printf", "ss() { return 7; }; unused() { printf"))
    refute status.success?, output
    assert_includes output, "Cannot inspect ingress listeners"
  end

  def test_upgrade_reconfigures_ingress_only_after_backup_and_restores_old_env_on_failure
    original = root_command("cat", "#{@config}/env")
    script = <<~SH
      source=reviewed; commit=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb; backup=point; listen_address=203.0.113.9
      ss() { :; }
      vps_archive() { echo ARCHIVE; }
      vps_backup() { cp "$VPS_CONFIG/env" "$VPS_STATE/saved.env"; echo BACKUP; }
      vps_switch() { echo SWITCH; }
      vps_load() { vps_load_env; [[ $NAVISHAI_PUBLIC_LISTEN_ADDRESS == 203.0.113.9 ]]; echo LOAD; }
      vps_compose() { echo COMPOSE; }
      vps_pull_pins() { :; }
      vps_guard() { :; }
      vps_prepare() { echo MIGRATION; return 7; }
      vps_stop() { echo STOP; }
      vps_restore() { cp "$VPS_STATE/saved.env" "$VPS_CONFIG/env"; echo RESTORE; }
      vps_start() { echo MUST-NOT-START; }
      vps_upgrade
    SH
    output, status = shell(script)
    refute status.success?, output
    assert_match(/BACKUP\nSWITCH\nLOAD\nCOMPOSE\nCOMPOSE\nMIGRATION\nSTOP\nRESTORE\n/, output)
    refute_includes output, "MUST-NOT-START"
    assert_equal original, root_command("cat", "#{@config}/env")
    output, status = shell(script.sub("echo BACKUP;", "echo BACKUP; return 7;"))
    refute status.success?, output
    refute_includes output, "SWITCH"
    assert_equal original, root_command("cat", "#{@config}/env")
  end

  def test_single_command_upgrade_is_a_no_op_on_latest_main
    main = origin_with_commits("feat: first").last
    install_release(main)
    output, status = shell(upgrade_script)
    assert status.success?, output
    assert_includes output, "Already on latest main (#{main}); nothing to upgrade."
    refute_includes output, "MUST-NOT"
    # CI runs as non-root; these 0700 paths need a root view.
    assert root_command("sh", "-c", "test -d #{Shellwords.escape("#{@root}/root/navishai-source/.git")} && echo yes").include?("yes")
    refute root_command("sh", "-c", "test -e #{Shellwords.escape("#{@root}/root/navishai-backups")} && echo yes || :").include?("yes")
  end

  def test_single_command_upgrade_confirms_backs_up_upgrades_and_verifies
    installed, main = origin_with_commits("feat: first", "fix: second")
    install_release(installed)
    output, status = shell(upgrade_script)
    refute status.success?, output
    assert_includes output, "fix: second"
    refute_includes output, "feat: first"
    assert_includes output, "Confirm on a terminal, or add --yes."
    refute_includes output, "MUST-NOT"
    output, status = shell(upgrade_script.sub("yes=false", "yes=true").gsub("MUST-NOT-", ""))
    assert status.success?, output
    assert_match(%r{ARCHIVE #{@root}/root/navishai-source #{main}\nBACKUP #{@root}/root/navishai-backups/\d{8}-\d{6}-#{installed[0, 7]}-to-#{main[0, 7]}\nCANDIDATE\n}, output)
    assert_match(/Recovery point: .*\nCHECK\nSTATUS\n\z/, output)
    assert_equal "700", root_command("stat", "-c", "%a", "#{@root}/root/navishai-backups").strip
  end

  def test_pinned_upgrade_keeps_explicit_source_commit_and_backup_without_fetching
    output, status = shell(upgrade_script.sub("yes=false", "yes=false; source=#{@directory}/reviewed; commit=#{'b' * 40}; backup=#{@directory}/point").gsub("MUST-NOT-", ""))
    assert status.success?, output
    assert_match(%r{\AARCHIVE #{@directory}/reviewed #{'b' * 40}\nBACKUP #{@directory}/point\nCANDIDATE\n}, output)
    refute root_command("sh", "-c", "test -e #{Shellwords.escape("#{@root}/root/navishai-source")} && echo yes || :").include?("yes")
  end

  def test_legacy_command_is_renamed_once_and_units_follow
    legacy = "#{@root}/usr/local/bin/navishai-reset"
    root_command("mv", "#{@root}/usr/local/bin/navishai", legacy)
    %w[navishai-reset.service navishai-reset-check.service].each do |unit|
      root_command("sed", "-i", "s#bin/navishai --root#bin/navishai-reset --root#", "#{@units}/#{unit}")
    end
    timer = root_command("cat", "#{@units}/navishai-reset-check.timer")
    output, status = shell("systemctl() { echo \"SYSTEMD $*\"; }; vps_rename_cli; vps_rename_cli")
    assert status.success?, output
    assert_equal [ "SYSTEMD daemon-reload", "Renamed the command: use sudo navishai from now on." ], output.lines.map(&:strip)
    refute File.symlink?(legacy)
    assert_equal "#{@prefix}/current/bin/navishai-vps", File.readlink("#{@root}/usr/local/bin/navishai")
    assert_equal "ExecStart=#{@root}/usr/local/bin/navishai --root #{@root} start\n", root_command("cat", "#{@units}/navishai-reset.service")
    assert_equal "644", root_command("stat", "-c", "%a", "#{@units}/navishai-reset-check.service").strip
    assert_equal timer, root_command("cat", "#{@units}/navishai-reset-check.timer")
    output, status = cleanup
    assert status.success?, output
  end

  def test_legacy_rename_refuses_foreign_links_and_units_without_changes
    legacy = "#{@root}/usr/local/bin/navishai-reset"
    root_command("rm", "-f", "#{@root}/usr/local/bin/navishai")
    root_command("ln", "-s", "/usr/bin/true", legacy)
    output, status = shell("systemctl() { echo MUST-NOT-RUN; }; vps_rename_cli")
    refute status.success?, output
    assert_includes output, "Unclaimed legacy CLI"
    refute_includes output, "MUST-NOT-RUN"
    refute File.symlink?("#{@root}/usr/local/bin/navishai")
    root_command("ln", "-sfn", "#{@prefix}/current/bin/navishai-vps", legacy)
    root_command("chmod", "0666", "#{@units}/navishai-reset.service")
    output, status = shell("systemctl() { echo MUST-NOT-RUN; }; vps_rename_cli")
    refute status.success?, output
    assert_includes output, "Unclaimed unit"
    assert File.symlink?(legacy)
    refute File.symlink?("#{@root}/usr/local/bin/navishai")
  end

  def test_bootstrap_renewal_refuses_completed_owner_and_never_prints_token
    script = <<~SH
      vps_stop() { echo STOP; }; vps_guard() { echo GUARD; }
      vps_compose() { echo RENEWABLE; }
      vps_renew_bootstrap
    SH
    output, status = shell(script)
    assert status.success?, output
    assert_match(/STOP\nGUARD\nRENEWABLE\n/, output)
    refute_match(/[0-9a-f]{96}/, output)
    saved = root_command("cat", "#{@config}/env")
    assert_match(/^NAVISHAI_BOOTSTRAP_TOKEN='[0-9a-f]{96}'$/, saved)
    output, status = shell(script.sub("echo RENEWABLE;", "echo RENEWABLE; return 7;"))
    refute status.success?, output
    assert_equal saved, root_command("cat", "#{@config}/env")
  end

  def test_guided_resume_uses_owned_release_without_source_or_commit
    script = resume_script
    original = root_command("cat", "#{@config}/env")
    output, status = shell(script)
    assert status.success?, output
    assert_match(/OWNERSHIP\nSTOP\nINGRESS\nFINISH\nACCOUNT\n/, output)
    assert_operator output.index("Review nonsecret"), :<, output.index("OWNERSHIP")
    assert_equal original, root_command("cat", "#{@config}/env")
    refute_includes output, "owner-private-password"
    assert_empty mutations

    output, status = shell(script.sub("install --resume", "install --resume --source #{Shellwords.escape(@directory)} --commit #{SHA}"))
    assert status.success?, output
    assert_includes output, "ACCOUNT"
    assert_equal original, root_command("cat", "#{@config}/env")
  end

  def test_resume_refuses_wrong_commit_or_receipt_before_collecting_account_and_checks_ownership
    script = resume_script
    output, status = shell(script.sub("install --resume", "install --resume --commit #{'b' * 40}"))
    refute status.success?, output
    assert_includes output, "installed commit"
    refute_includes output, "Review nonsecret"
    refute_includes output, "STOP"

    output, status = shell(script.sub("echo OWNERSHIP >&2;", "echo OWNERSHIP >&2; return 7;"))
    refute status.success?, output
    assert_includes output, "OWNERSHIP"
    refute_includes output, "STOP"
    refute_includes output, "ACCOUNT"

    write_private("#{@release}/SOURCE_COMMIT", "#{'b' * 40}\n")
    output, status = shell(script)
    refute status.success?, output
    refute_includes output, "Review nonsecret"
    refute_includes output, "STOP"
    assert_empty mutations
  end

  def test_owned_units_can_resume_but_foreign_contents_still_refuse
    names = %w[navishai-reset.service navishai-reset-check.service navishai-reset-check.timer]
    root_command("rm", "-f", *names.map { |name| "#{@units}/#{name}" })
    output, status = shell("systemctl() { echo SYSTEMD; }; vps_units; vps_units")
    assert status.success?, output
    assert_equal 4, output.lines.count { |line| line.strip == "SYSTEMD" }
    root_command("sh", "-c", "echo foreign >> #{Shellwords.escape("#{@units}/navishai-reset.service")}")
    output, status = shell("systemctl() { echo MUST-NOT-RUN; }; vps_units")
    refute status.success?, output
    refute_includes output, "MUST-NOT-RUN"
    assert_includes root_command("cat", "#{@units}/navishai-reset.service"), "foreign"
  end

  def test_destination_recovery_requires_consent_and_an_empty_target
    output, status = shell("from=not-a-backup; confirmation=; vps_fresh_check() { echo MUST-NOT-RUN; }; vps_recover")
    refute status.success?, output
    refute_includes output, "MUST-NOT-RUN"
    write_private("#{@directory}/CHECKSUMS", "consent fixture\n")
    digest = root_command("sha256sum", "#{@directory}/CHECKSUMS").split.first
    output, status = shell("from=#{Shellwords.escape(@directory)}; confirmation=#{digest}; vps_recover")
    refute status.success?, output
    assert_includes output, "Fresh install path exists"
    assert File.exist?("#{@config}/env")
  end

  def test_destination_resume_refuses_other_installations_and_checks_owned_resources
    write_private("#{@directory}/CHECKSUMS", "consent fixture\n")
    digest = root_command("sha256sum", "#{@directory}/CHECKSUMS").split.first
    script = <<~SH
      from=#{Shellwords.escape(@directory)}; confirmation=#{digest}; resume=true
      vps_load() { echo LOAD; }
      vps_cleanup_plan() { echo OWNERSHIP >&2; return 7; }
      vps_fresh_check() { echo MUST-NOT-ADOPT; return 7; }
      vps_recover
    SH
    output, status = shell(script)
    refute status.success?, output
    refute_includes output, "OWNERSHIP"
    refute_includes output, "MUST-NOT-ADOPT"
    output, status = shell("vps_receipt #{SHA} recovering; #{script}")
    refute status.success?, output
    assert_includes output, "LOAD"
    assert_includes output, "OWNERSHIP"
    refute_includes output, "MUST-NOT-ADOPT"
    assert File.exist?("#{@config}/env")
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
      vps_ingress_check() { echo INGRESS; }
      vps_dns_check() { echo DNS; }
      vps_compose() { printf 'COMPOSE %s\n' "$*"; }
      vps_policy_apply() { echo APPLY; }
      vps_policy_check() { echo CHECK; }
      vps_validate() { echo VALIDATE; }
      vps_runtime_check() { echo RUNTIME; }
      vps_ingress_binding_check() { echo BINDING; }
      vps_https() { echo TLS; }
      curl() { echo HEALTH; }
      vps_receipt() { echo READY; }
      vps_start
    SH
    output, status = shell(script)
    assert status.success?, output
    assert_equal [ "STOP", "INGRESS", "DNS", "COMPOSE up -d --pull never --no-build --no-deps --wait postgres", "COMPOSE up -d --pull never --no-build --no-deps --force-recreate --wait app-net", "APPLY", "CHECK", "VALIDATE", "COMPOSE up --no-start --pull never --no-build --no-deps --force-recreate web jobs", "RUNTIME", "CHECK", "COMPOSE start web jobs", "CHECK", "COMPOSE up -d --pull never --no-build --no-deps proxy", "BINDING", "TLS", "READY" ], output.lines.map(&:strip)
    output, status = shell(script.sub("echo INGRESS;", "echo INGRESS; return 7;"))
    refute status.success?, output
    assert_equal "STOP\nINGRESS\n", output
    output, status = shell(script.sub("echo RUNTIME;", "echo RUNTIME; return 7;"))
    refute status.success?, output
    refute_includes output, "COMPOSE start web jobs"
    refute_includes output, "READY"
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

  def test_pinned_images_use_exact_cache_and_pull_only_a_missing_reference
    postgres = "postgres:16@sha256:#{'1' * 64}"
    proxy = "caddy:2@sha256:#{'2' * 64}"
    configuration = { services: { postgres: { image: postgres }, proxy: { image: proxy } } }
    output, status = shell(<<~SH)
      vps_compose() { echo '#{JSON.generate(configuration)}'; }
      vps_docker() {
        if [[ $1 == pull ]]; then echo "PULL $2"; cached=true
        elif [[ ${!#} == #{Shellwords.escape(postgres)} || ${cached:-false} == true ]]; then echo sha256:#{'9' * 64}
        else echo "Error response from daemon: No such image: ${!#}" >&2; return 1; fi
      }
      vps_pull_pins
    SH
    assert status.success?, output
    assert_equal "PULL #{proxy}\n", output
    # API/daemon failure must not turn into a network attempt.
    output, status = shell(<<~SH)
      vps_compose() { echo '#{JSON.generate(configuration)}'; }
      vps_docker() { if [[ $1 == pull ]]; then echo MUST-NOT-PULL; else echo 'Cannot connect to Docker daemon' >&2; return 1; fi; }
      vps_pull_pins
    SH
    refute status.success?, output
    refute_includes output, "MUST-NOT-PULL"
  end

  def test_pinned_image_pull_failure_stops_before_next_service_without_retry
    configuration = { services: { postgres: { image: "postgres:16@sha256:#{'1' * 64}" }, proxy: { image: "caddy:2@sha256:#{'2' * 64}" } } }
    output, status = shell(<<~SH)
      vps_compose() { echo '#{JSON.generate(configuration)}'; }
      vps_docker() { if [[ $1 == pull ]]; then echo "PULL $2"; return 7; else echo "No such image: ${!#}" >&2; return 1; fi; }
      vps_pull_pins
    SH
    refute status.success?, output
    assert_equal "PULL postgres:16@sha256:#{'1' * 64}\n", output
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
      NAVISHAI_PUBLIC_LISTEN_ADDRESS=203.0.113.9
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
      vps_ingress_check() { :; }
      vps_archive() { mkdir -p "$VPS_PREFIX/releases"; echo ARCHIVE >&2; return 7; }
      vps_install
    SH
    refute status.success?, output
    assert_includes output, "ARCHIVE"
    %w[opt/navishai-reset etc/navishai-reset var/lib/navishai-reset].each do |path|
      refute File.exist?("#{@directory}/fresh/#{path}")
    end
    assert File.exist?("#{@config}/env")
    assert File.exist?(@release)
  end

  def test_partial_install_cleanup_requires_receipt_and_not_env_or_missing_units
    root_command("rm", "-f", "#{@root}/usr/local/bin/navishai", "#{@config}/env",
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
    route = "listen_address=auto; "
    output, status = shell(route + "host=support.example.test; email=owner@example.test; output=#{Shellwords.escape("#{@directory}/new.env")}; vps_init_env; stat -c '%u:%a' \"$output\"")
    assert status.success?, output
    assert_includes output, "0:600"
    refute_match(/[0-9a-f]{96}/, output)
    values = root_command("cat", "#{@directory}/new.env").scan(/^NAVISHAI_(?:DATABASE|POSTGRES|PREPARE)_PASSWORD='([0-9a-f]{96})'$/).flatten
    assert_equal 3, values.length
    assert_equal 3, values.uniq.length
    assert_includes root_command("cat", "#{@directory}/new.env"), "NAVISHAI_PUBLIC_LISTEN_ADDRESS='auto'"
    output, status = shell(route + "host=support.example.test; email=owner@example.test; output=#{Shellwords.escape("#{@directory}/new.env")}; vps_init_env")
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

  def origin_with_commits(*subjects)
    origin = "#{@directory}/origin.git"
    work = "#{@directory}/origin-work"
    script = +"git init -q --bare -b main #{Shellwords.escape(origin)} && git init -q -b main #{Shellwords.escape(work)}"
    subjects.each do |subject|
      script << " && git -C #{Shellwords.escape(work)} -c user.name=Fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m #{Shellwords.escape(subject)}"
    end
    script << " && git -C #{Shellwords.escape(work)} push -q #{Shellwords.escape(origin)} main"
    root_command("sh", "-c", script)
    freeze_files
    root_command("git", "-C", work, "log", "--reverse", "--format=%H").split
  end

  def install_release(sha)
    root_command("sh", "-c", "echo #{sha} > #{Shellwords.escape("#{@release}/SOURCE_COMMIT")}")
  end

  def upgrade_script
    <<~SH
      VPS_REPOSITORY=#{Shellwords.escape("#{@directory}/origin.git")}; source= commit= backup= listen_address=; yes=false
      vps_archive() { echo "MUST-NOT-ARCHIVE $1 $2" >&2; }
      vps_resolve_ingress() { :; }
      vps_backup() { echo "MUST-NOT-BACKUP $1"; }
      vps_candidate() { echo MUST-NOT-CANDIDATE; }
      vps_check() { echo MUST-NOT-CHECK; }
      vps_status() { echo MUST-NOT-STATUS; }
      vps_upgrade
    SH
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
    Open3.capture2e(*root_command_args, "bash", "-euo", "pipefail", "-c", "source ops/vps/cli.sh; vps_paths #{Shellwords.escape(@root)}; VPS_RELEASE=#{Shellwords.escape(@release)}; #{host_network} #{script}", chdir: ROOT)
  end

  def resume_script
    root_command("mkdir", "-p", "#{@release}/ops/vps")
    %w[policy recovery].each { |name| write_private("#{@release}/ops/vps/#{name}.sh", "# inert release fixture\n") }
    write_private("#{@directory}/answers.json", JSON.generate(
      host: "support.example.test", acme_email: "owner@example.test", smtp_server: "smtp.example.test",
      smtp_port: "587", smtp_user: "test-only-user", smtp_password: "test-only-secret", smtp_from: "owner@example.test",
      owner_email: "owner@example.test", owner_password: "owner-private-password", owner_password_confirmation: "owner-private-password",
      organization_name: "Example Org", organization_slug: "example-org", workspace_name: "Support Lab", workspace_slug: "support-lab"
    ))
    <<~SH
      vps_doctor() { :; }
      vps_cleanup_plan() { echo OWNERSHIP >&2; }
      vps_stop() { echo STOP; }
      vps_ingress_check() { echo INGRESS; }
      vps_finish_install() { flock -u "$VPS_LOCK"; echo FINISH; }
      vps_compose() { jq -e '.email_address == "owner@example.test" and .password == "owner-private-password"' >/dev/null && echo ACCOUNT; }
      vps_main --root #{Shellwords.escape(@root)} install --resume --non-interactive --answers #{Shellwords.escape("#{@directory}/answers.json")}
    SH
  end

  def host_network(*addresses)
    addresses = [ "203.0.113.9" ] if addresses.empty?
    interfaces = [ { ifname: "eth0", addr_info: addresses.map { |address| { local: address, scope: "global" } } },
      { ifname: "tailscale0", addr_info: [ { local: "100.98.160.115", scope: "global" } ] } ]
    <<~SH
      ip() {
        case "$*" in
          '-j -4 address show up') printf '%s\n' #{Shellwords.escape(JSON.generate(interfaces))} ;;
          '-j -4 route show table main default') echo '[{"dev":"eth0"}]' ;;
          '-j -4 route get 1.1.1.1 from '*) echo '[{"dev":"eth0"}]' ;;
          *) return 7 ;;
        esac
      };
    SH
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
