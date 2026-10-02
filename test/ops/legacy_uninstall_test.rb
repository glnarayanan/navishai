require "minitest/autorun"
require "fileutils"
require "json"
require "open3"
require "tmpdir"

class LegacyUninstallTest < Minitest::Test
  SCRIPT = File.expand_path("../../bin/uninstall-navishai-old", __dir__)
  HISTORY = "94180d277e624d4b478efd3e3048e0a1c67358d5"

  def setup
    @directory = Dir.mktmpdir("navishai-uninstall-test-")
    FileUtils.chmod(0755, @directory)
    @root = File.join(@directory, "managed")
    @release = File.join(@root, "opt/navishai/releases", "a" * 64)
    @bin = File.join(@directory, "bin")
    FileUtils.mkdir_p([ @bin, @release, "#{@root}/etc/navishai", "#{@root}/var/lib/navishai", "#{@root}/var/backups/navishai", "#{@root}/usr/local/bin" ])
    # Layout and config-label paths come from HISTORY and the first CLI release
    # e8dba3a. Contents never execute; keep tests usable in shallow CI checkouts.
    %w[compose.yaml ops/installer/compose.yaml ops/installer/navishai].each do |path|
      FileUtils.mkdir_p(File.dirname(File.join(@release, path)))
      File.write(File.join(@release, path), "# Historical installer layout fixture: #{HISTORY}\n")
    end
    File.write("#{@release}/SOURCE_COMMIT", HISTORY)
    File.write("#{@root}/etc/navishai/env", "SECRET_KEY_BASE=must-not-print-this\n")
    File.write("#{@root}/var/lib/navishai/install.lock", "")
    File.symlink(@release, "#{@root}/opt/navishai/current")
    File.symlink("#{@root}/opt/navishai/current/ops/installer/navishai", "#{@root}/usr/local/bin/navishai")
    @fixture = {
      "containers" => [ { "id" => "1" * 64, "project" => "old-custom", "service" => "web",
        "files" => "#{@root}/opt/navishai/current/compose.yaml,#{@root}/opt/navishai/current/ops/installer/compose.yaml",
        "mounts" => [ { "Type" => "volume", "Name" => "old-custom_postgres_data" },
          { "Type" => "bind", "Source" => "#{@root}/etc/navishai", "Destination" => "/old-config" } ] },
        { "id" => "2" * 64, "project" => "other-app", "service" => "web", "files" => "/other/compose.yaml", "mounts" => [] } ],
      "volumes" => { "old-custom_postgres_data" => "postgres_data" },
      "networks" => [ { "id" => "3" * 64, "key" => "control", "containers" => { "1" * 64 => {} } } ],
      "mounts" => { "filesystems" => [ { "target" => "/" } ] }, "units" => ""
    }
    File.write("#{@bin}/docker", <<~'RUBY')
      #!/usr/bin/env ruby
      require "json"
      f = JSON.parse(File.read(ENV.fetch("UNINSTALL_FIXTURE")))
      a = ARGV
      case a.first
      when "context" then puts "unix:///var/run/docker.sock"
      when "info" then puts "test-local-daemon"
      when "ps" then f.fetch("containers").each { |c| puts c.fetch("id") }
      when "inspect" then f.fetch("containers").each { |c| puts JSON.generate(c) }
      when "volume"
        case a[1]
        when "ls" then puts f.fetch("volumes").keys
        when "inspect" then puts f.fetch("volumes").fetch(a.last)
        when "rm" then File.open(ENV.fetch("UNINSTALL_LOG"), "a", 0644) { |io| io.puts JSON.generate(a) }
        else abort "Unexpected volume command"
        end
      when "network"
        case a[1]
        when "ls" then f.fetch("networks").each { |n| puts n.fetch("id") }
        when "inspect" then puts JSON.generate(f.fetch("networks").find { |n| n.fetch("id") == a.last })
        when "rm" then File.open(ENV.fetch("UNINSTALL_LOG"), "a", 0644) { |io| io.puts JSON.generate(a) }
        else abort "Unexpected network command"
        end
      when "stop", "rm"
        exit 7 if a.first == "stop" && f["stop_fail"]
        File.open(ENV.fetch("UNINSTALL_LOG"), "a", 0644) { |io| io.puts JSON.generate(a) }
      else abort "Unexpected Docker command"
      end
    RUBY
    File.write("#{@bin}/findmnt", "#!/usr/bin/env ruby\nrequire 'json'\nputs JSON.parse(File.read(ENV.fetch('UNINSTALL_FIXTURE'))).fetch('mounts').to_json\n")
    File.write("#{@bin}/systemctl", "#!/usr/bin/env ruby\nrequire 'json'\nprint JSON.parse(File.read(ENV.fetch('UNINSTALL_FIXTURE'))).fetch('units')\n")
    FileUtils.chmod(0755, Dir.glob("#{@bin}/*"))
    @fixture_path = "#{@directory}/fixture.json"
    @log = "#{@directory}/mutations.jsonl"
    File.write(@log, "")
    root_command("chown", "-R", "root:root", @directory)
  end

  def teardown
    root_command("rm", "-rf", "--", @directory) if @directory
  end

  def test_preview_is_read_only_and_uses_the_historical_layout
    output, status = run_script
    assert status.success?, output
    assert_includes output, '"project": "old-custom"'
    assert_includes output, "PREVIEW ONLY"
    refute_includes output, "must-not-print-this"
    assert_empty mutations
    assert File.symlink?("#{@root}/usr/local/bin/navishai")
  end

  def test_confirmed_apply_targets_only_exact_old_resources
    output, status = run_script
    assert status.success?, output
    digest = output.match(/Plan digest: ([0-9a-f]{64})/)[1]
    output, status = run_script("--apply", "--confirm-destroy", digest)
    assert status.success?, output
    calls = mutations
    assert_equal [ "stop", "rm", "network", "volume" ], calls.map(&:first)
    assert_equal [ "stop", "--time", "30", "1" * 64 ], calls.first
    refute calls.flatten.include?("2" * 64)
    refute File.exist?("#{@root}/opt/navishai")
    refute File.symlink?("#{@root}/usr/local/bin/navishai")
  end

  def test_wrong_digest_and_stop_failure_preserve_files
    output, status = run_script("--apply", "--confirm-destroy", "0" * 64)
    refute status.success?
    assert_includes output, "Plan changed"
    assert_empty mutations
    output, = run_script
    digest = output.match(/Plan digest: ([0-9a-f]{64})/)[1]
    @fixture["stop_fail"] = true
    _, status = run_script("--apply", "--confirm-destroy", digest)
    refute status.success?
    assert File.exist?(@release)
    assert_empty mutations
  end

  def test_shared_volume_and_each_direction_of_bind_overlap_refuse
    [ { "Type" => "volume", "Name" => "old-custom_postgres_data" },
      { "Type" => "bind", "Source" => "#{@root}/etc/navishai" },
      { "Type" => "bind", "Source" => "#{@root}/etc" },
      { "Type" => "bind", "Source" => "#{@root}/etc/navishai/subdirectory" },
      { "Type" => "bind", "Source" => "/" } ].each do |mount|
      @fixture["containers"].last["mounts"] = [ mount ]
      output, status = run_script
      refute status.success?, output
      assert_match(/shares/, output)
      assert_empty mutations
    end
  end

  def test_same_project_foreign_config_and_shared_network_refuse
    @fixture["containers"].last["project"] = "old-custom"
    output, status = run_script
    refute status.success?
    assert_includes output, "another config"
    @fixture["containers"].last["project"] = "other-app"
    @fixture["networks"].first["containers"]["2" * 64] = {}
    output, status = run_script
    refute status.success?
    assert_includes output, "unrelated container"
    assert_empty mutations
  end

  def test_nested_host_mount_and_extra_service_refuse
    @fixture["mounts"]["filesystems"] << { "target" => "#{@release}/nested" }
    output, status = run_script
    refute status.success?
    assert_includes output, "Mounted filesystem"
    @fixture["mounts"]["filesystems"].pop
    @fixture["units"] = "navishai-web.service enabled enabled\n"
    output, status = run_script
    refute status.success?
    assert_includes output, "systemd units"
    assert_empty mutations
  end

  def test_external_volume_requires_its_own_explicit_option
    @fixture["containers"].first["mounts"] << { "Type" => "volume", "Name" => "external_old_data" }
    output, status = run_script
    assert status.success?, output
    digest = output.match(/Plan digest: ([0-9a-f]{64})/)[1]
    output, status = run_script("--apply", "--confirm-destroy", digest)
    assert status.success?, output
    refute mutations.flatten.include?("external_old_data")
  end

  def test_unproven_extra_targets_and_symlink_escape_refuse
    output, status = run_script("--delete-volume", "unrelated_database")
    refute status.success?
    assert_includes output, "not mounted"
    root_command("rm", "#{@root}/opt/navishai/current")
    root_command("ln", "-s", @directory, "#{@root}/opt/navishai/current")
    output, status = run_script
    refute status.success?
    assert_includes output, "escapes"
    assert_empty mutations
  end

  private

  def root_command(*args)
    output, status = Open3.capture2e("sudo", "-n", *args)
    raise output unless status.success?
    output
  end

  def run_script(*args)
    # Only the named temporary fixture is root-owned. Every Docker call is mocked.
    writer, status = Open3.capture2e("sudo", "-n", "tee", @fixture_path, stdin_data: @fixture.to_json)
    raise writer unless status.success?
    root_command("chmod", "0644", @fixture_path)
    Open3.capture2e("sudo", "-n", "env", "PATH=#{@bin}:#{File.dirname(RbConfig.ruby)}:#{ENV.fetch('PATH')}",
      "UNINSTALL_FIXTURE=#{@fixture_path}", "UNINSTALL_LOG=#{@log}",
      "bash", SCRIPT, "--root", @root, *args)
  end

  def mutations
    File.readlines(@log).map { |line| JSON.parse(line) }
  end
end
