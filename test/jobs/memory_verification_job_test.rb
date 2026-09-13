require "test_helper"
require_relative "../test_helpers/fake_memory_engine"

class MemoryVerificationJobTest < ActiveJob::TestCase
  test "continues a pending index without duplicating the synthetic record" do
    workspace = workspaces(:acme_support)
    owner = memberships(:owner_support)
    engine = FakeMemoryEngine.new
    engine.index_status = "queued"
    original = SupermemoryEngine.method(:default)
    SupermemoryEngine.define_singleton_method(:default) { engine }

    with_memory_env do
      MemoryVerificationCheck.run!(
        workspace:, membership: owner, engine:, foreign_workspace: workspaces(:acme_success),
        poll_attempts: 0
      )
      engine.index_status = "done"
      perform_enqueued_jobs only: MemoryVerificationJob

      assert_equal 0, workspace.memory_records.available.where(topic: MemoryVerificationCheck::TOPIC).count
      assert_equal "verified", MemoryVerificationCheck.latest_for_current_configuration(workspace).result_code
    end
  ensure
    SupermemoryEngine.define_singleton_method(:default, original)
  end

  private
    def with_memory_env
      original = ENV.to_h.slice("NAVISHAI_SUPERMEMORY_ADDRESS", "NAVISHAI_SUPERMEMORY_API_KEY", "NAVISHAI_SOURCE_COMMIT")
      ENV["NAVISHAI_SUPERMEMORY_ADDRESS"] = "http://127.0.0.1:6767"
      ENV["NAVISHAI_SUPERMEMORY_API_KEY"] = "sm_#{"a" * 32}"
      ENV["NAVISHAI_SOURCE_COMMIT"] = "c" * 40
      yield
    ensure
      %w[NAVISHAI_SUPERMEMORY_ADDRESS NAVISHAI_SUPERMEMORY_API_KEY NAVISHAI_SOURCE_COMMIT].each do |key|
        original.key?(key) ? ENV[key] = original[key] : ENV.delete(key)
      end
    end
end
