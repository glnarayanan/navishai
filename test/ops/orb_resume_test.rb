require "minitest/autorun"
require "open3"
require "tmpdir"

class OrbResumeTest < Minitest::Test
  RESUME = File.expand_path("../../.agents/resume", __dir__)

  def test_refuses_missing_or_conflicting_current_cluster_without_changing_existing_clusters
    Dir.mktmpdir("navishai-orb-resume") do |directory|
      changed = File.join(directory, "cluster-changed")
      [ "16 main 5432 online postgres /data /log", "18 main 5433 down postgres /data /log" ].each do |clusters|
        output, status = Open3.capture2e(
          { "CLUSTERS" => clusters, "CHANGED" => changed },
          "bash", "-c", <<~SH, "bash", RESUME
            pg_lsclusters() { printf '%s\n' "$CLUSTERS"; }
            pg_isready() { return 0; }
            sudo() { touch "$CHANGED"; }
            export -f pg_lsclusters pg_isready sudo
            bash "$1"
          SH
        )

        refute status.success?, output
        assert_includes output, "PostgreSQL 18/main"
        refute File.exist?(changed), "resume must not change existing clusters to resolve a version or port conflict"
      end
    end
  end
end
