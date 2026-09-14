require "test_helper"
require "fileutils"
require "open3"
require "tmpdir"

class CandidateBundleTest < ActiveSupport::TestCase
  REQUIRED = %w[
    compose.yaml Dockerfile ops/docker/runner.Dockerfile ops/docker/supermemory.Dockerfile
    ops/compose/backup ops/compose/lib.sh ops/compose/restore ops/compose/upgrade_preflight ops/compose/verify_backup
    ops/installer/Caddyfile ops/installer/bootstrap ops/installer/compose.yaml ops/installer/navishai
    ops/runner/execution.example.json script/generate_runner_tls
  ].freeze

  test "packages only committed exported bytes and excludes ignored sentinels" do
    with_fixture do |root, bin, commit|
      File.write("#{root}/ops/compose/backup", "dirty\n")
      File.write("#{root}/.env", "sentinel-env\n")
      FileUtils.mkdir_p("#{root}/ops/secrets")
      File.write("#{root}/ops/secrets/sentinel", "sentinel-secret\n")
      output = "#{root}/candidate.tar"

      _stdout, stderr, status = run_builder(root, bin, output, commit)

      assert status.success?, stderr
      Dir.mktmpdir do |unpacked|
        system("tar", "-xf", output, "-C", unpacked, exception: true)
        assert_equal "committed\n", File.read("#{unpacked}/release/ops/compose/backup")
        assert_equal "#{commit}\n", File.read("#{unpacked}/release/SOURCE_COMMIT")
        refute File.exist?("#{unpacked}/release/.env")
        refute File.exist?("#{unpacked}/release/ops/secrets/sentinel")
      end
      log = File.read("#{root}/docker.log")
      assert_includes log, "compose --env-file"
      refute_includes log, root
      assert_equal "clean\n", File.read("#{root}/context.log")
    end
  end

  test "rejects a revision missing required payload before Docker" do
    with_fixture(remove: "ops/installer/navishai") do |root, bin, commit|
      _stdout, stderr, status = run_builder(root, bin, "#{root}/candidate.tar", commit)

      assert_not status.success?
      assert_includes stderr, "missing required payload"
      commands = File.readlines("#{root}/docker.log", chomp: true)
      refute commands.any? { |command| command.include?(" compose ") || command.include?("image save") }
    end
  end

  test "loads retained infrastructure images before selectively rebuilding Rails" do
    with_fixture do |root, bin, commit|
      retained = "#{root}/retained-images.tar"
      File.write(retained, "retained")

      _stdout, stderr, status = run_builder(root, bin, "#{root}/candidate.tar", commit,
        "NAVISHAI_REUSE_INFRA_IMAGES_ARCHIVE" => retained)

      assert status.success?, stderr
      commands = File.readlines("#{root}/docker.log", chomp: true)
      load_index = commands.index { |command| command == "image load -i #{retained}" }
      build_index = commands.index { |command| command.include?("compose") && command.end_with?("build web jobs") }
      save_index = commands.index { |command| command.start_with?("image save ") }
      assert_not_nil load_index
      assert_not_nil build_index
      assert_not_nil save_index
      assert_operator load_index, :<, build_index
      assert_operator build_index, :<, save_index
    end
  end

  private

    def with_fixture(remove: nil)
      Dir.mktmpdir do |root|
        FileUtils.cp(Rails.root.join("script/candidate_bundle"), "#{root}/candidate_bundle")
        REQUIRED.each do |path|
          next if path == remove
          target = "#{root}/#{path}"
          FileUtils.mkdir_p(File.dirname(target))
          File.write(target, path == "ops/compose/backup" ? "committed\n" : "fixture\n")
        end
        FileUtils.chmod(0o755, "#{root}/candidate_bundle")
        system("git", "init", "-q", root, exception: true)
        system("git", "-C", root, "add", ".", exception: true)
        system("git", "-C", root, "-c", "commit.gpgsign=false", "-c", "user.name=test", "-c", "user.email=test@example.test", "commit", "-qm", "fixture", exception: true)
        commit = `git -C #{root} rev-parse HEAD`.strip
        bin = "#{root}/bin"
        FileUtils.mkdir_p(bin)
        File.write("#{bin}/docker", "#!/bin/sh\nprintf '%s\\n' \"$*\" >>\"$FAKE_DOCKER_LOG\"\ncase \"$*\" in *'compose '* ) set -- $*; while [ \"$#\" -gt 0 ]; do [ \"$1\" = -f ] && { dir=$(dirname \"$2\"); [ -e \"$dir/.env\" ] || [ -e \"$dir/ops/secrets/sentinel\" ] || printf 'clean\\n' >\"$FAKE_CONTEXT_LOG\"; break; }; shift; done;; *'image save'*) printf image;; esac\n")
        FileUtils.chmod(0o755, "#{bin}/docker")
        yield root, bin, commit
      end
    end

    def run_builder(root, bin, output, commit, environment = {})
      Open3.capture3({ "PATH" => "#{bin}:#{ENV.fetch('PATH')}", "FAKE_DOCKER_LOG" => "#{root}/docker.log", "FAKE_CONTEXT_LOG" => "#{root}/context.log" }.merge(environment), "#{root}/candidate_bundle", output, commit, chdir: root)
    end
end
