require "test_helper"
require_relative "../test_helpers/fake_memory_engine"

class MemoryVerificationCheckTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @workspace = workspaces(:acme_support)
    @foreign = workspaces(:acme_success)
    @owner = memberships(:owner_support)
    @engine = FakeMemoryEngine.new
    @memory_env = ENV.to_h.slice("NAVISHAI_SUPERMEMORY_ADDRESS", "NAVISHAI_SUPERMEMORY_API_KEY", "NAVISHAI_SOURCE_COMMIT", "NAVISHAI_MEMORY_PENDING")
    ENV["NAVISHAI_SUPERMEMORY_ADDRESS"] = "http://127.0.0.1:6767"
    ENV["NAVISHAI_SUPERMEMORY_API_KEY"] = "sm_#{"a" * 32}"
    ENV["NAVISHAI_SOURCE_COMMIT"] = "c" * 40
    ENV.delete("NAVISHAI_MEMORY_PENDING")
  end

  teardown do
    %w[NAVISHAI_SUPERMEMORY_ADDRESS NAVISHAI_SUPERMEMORY_API_KEY NAVISHAI_SOURCE_COMMIT NAVISHAI_MEMORY_PENDING].each do |key|
      @memory_env.key?(key) ? ENV[key] = @memory_env[key] : ENV.delete(key)
    end
  end

  test "records a pass after scoped index, retrieval, isolation, and removal" do
    outcome = run_check

    assert_equal "passed", outcome.result
    assert_equal "verified", outcome.result_code
    assert_equal "memory_verification", outcome.check.check_kind
    assert_equal @owner, outcome.check.recorded_by_membership
    assert_equal MemoryVerificationCheck.configuration_digest, outcome.check.evidence_digest
    assert_equal 0, @workspace.memory_records.available.where(topic: MemoryVerificationCheck::TOPIC).count
    assert @workspace.memory_tombstones.joins(:memory_record)
      .where(memory_records: { topic: MemoryVerificationCheck::TOPIC }).all?(&:index_status_removed?)
    assert_empty @engine.search(query: own_query("never-used"))
    assert AuditEvent.exists?(action: "operations.check_recorded", subject_type: "OperationalCheck", subject_id: outcome.check.id)
  end

  test "does not accumulate a second live synthetic record on a repeated check" do
    run_check
    run_check

    synthetics = @workspace.memory_records.where(topic: MemoryVerificationCheck::TOPIC)
    assert_operator synthetics.count, :>=, 1
    assert_equal 0, synthetics.merge(MemoryRecord.available).count
    assert synthetics.all? { |record| record.memory_tombstone&.index_status_removed? }
  end

  test "records indexing pending on timeout and does not mark the configuration verified" do
    @engine.index_status = "queued"
    assert_enqueued_with(job: MemoryVerificationJob) do
      outcome = run_check(poll_attempts: 0)
      assert_equal [ "pending", "indexing_pending" ], [ outcome.result, outcome.result_code ]
    end
    refute_equal "tested", WorkspaceSetupChecklist.new(@workspace).items.find { |item| item.name == "Memory" }.state
    assert MemoryVerificationCheck.latest_for_current_configuration(@workspace).result == "pending"
  end

  test "records retrieval mismatch when indexed memory is not returned for this Workspace" do
    @engine.search_miss = true
    outcome = run_check

    assert_equal [ "failed", "retrieval_mismatch" ], [ outcome.result, outcome.result_code ]
    refute verified?
  end

  test "records scope failure when another Workspace can retrieve the synthetic record" do
    @engine.leak_to_foreign = true
    outcome = run_check

    assert_equal [ "failed", "scope_failure" ], [ outcome.result, outcome.result_code ]
    refute verified?
  end

  test "records cleanup pending when removal does not finish" do
    @engine.remove_fails = true
    assert_enqueued_with(job: MemoryVerificationJob) do
      outcome = run_check
      assert_equal [ "pending", "cleanup_pending" ], [ outcome.result, outcome.result_code ]
    end
    refute verified?
    assert_equal 0, @workspace.memory_records.available.where(topic: MemoryVerificationCheck::TOPIC).count
  end

  test "records unavailable and authentication failure without using a managed host" do
    @engine.unavailable = true
    outcome = run_check
    assert_equal [ "unavailable", "memory_unavailable" ], [ outcome.result, outcome.result_code ]

    @engine.unavailable = false
    @engine.auth_error = true
    outcome = run_check
    assert_equal [ "failed", "authentication_failure" ], [ outcome.result, outcome.result_code ]
    refute verified?
  end

  test "binds the recorded check to non-secret configuration and requires a source version" do
    outcome = run_check
    assert_equal outcome.check, MemoryVerificationCheck.latest_for_current_configuration(@workspace)

    with_memory_env(address: "http://127.0.0.1:6768") do
      assert_nil MemoryVerificationCheck.latest_for_current_configuration(@workspace)
    end
    with_memory_env(source_commit: "") do
      assert_raises(MemoryVerificationCheck::SourceCommitUnavailable) { run_check }
    end
    with_memory_env(pending: "1") do
      assert_not MemoryVerificationCheck.configured?
      assert_raises(MemoryVerificationCheck::NotConfigured) { run_check }
    end
  end

  test "refuses a viewer and does not create a synthetic record" do
    viewer = @workspace.memberships.create!(user: users(:outsider), role: :viewer)

    assert_raises(Current::RoleAccessDenied) do
      MemoryVerificationCheck.run!(workspace: @workspace, membership: viewer, engine: @engine, foreign_workspace: @foreign)
    end
    assert_equal 0, @workspace.memory_records.where(topic: MemoryVerificationCheck::TOPIC).count
    assert_equal 0, OperationalCheck.where(check_kind: "memory_verification").count
  end

  test "continue finishes a queued index without creating another live record" do
    @engine.index_status = "queued"
    run_check(poll_attempts: 0)
    live = @workspace.memory_records.available.where(topic: MemoryVerificationCheck::TOPIC)
    assert_equal 1, live.count

    @engine.index_status = "done"
    @engine.status_done_after = 0
    assert_difference -> { live.reload.count }, -1 do
      outcome = MemoryVerificationCheck.continue!(
        workspace: @workspace, membership: @owner, engine: @engine, foreign_workspace: @foreign
      )
      assert_equal [ "passed", "verified" ], [ outcome.result, outcome.result_code ]
    end
  end

  private
    def run_check(poll_attempts: 5)
      MemoryVerificationCheck.run!(
        workspace: @workspace, membership: @owner, engine: @engine, foreign_workspace: @foreign,
        poll_attempts:
      )
    end

    def verified?
      check = MemoryVerificationCheck.latest_for_current_configuration(@workspace)
      item = WorkspaceSetupChecklist.new(@workspace).items.find { |entry| entry.name == "Memory" }
      check&.result == "passed" && check.result_code == "verified" && item.state == "tested"
    end

    def own_query(text)
      MemoryEngine::Query.new(
        organization_key: @workspace.organization_id.to_s, workspace_key: @workspace.runner_key,
        text:, scope_filters: [ MemoryEngine::ScopeFilter.new(kind: "workspace", key: @workspace.id.to_s) ],
        limit: 5
      )
    end

    def with_memory_env(address: "http://127.0.0.1:6767", source_commit: "c" * 40, pending: nil)
      keys = %w[NAVISHAI_SUPERMEMORY_ADDRESS NAVISHAI_SUPERMEMORY_API_KEY NAVISHAI_SOURCE_COMMIT NAVISHAI_MEMORY_PENDING]
      original = ENV.to_h.slice(*keys)
      ENV["NAVISHAI_SUPERMEMORY_ADDRESS"] = address
      ENV["NAVISHAI_SUPERMEMORY_API_KEY"] = "sm_#{"a" * 32}"
      ENV["NAVISHAI_SOURCE_COMMIT"] = source_commit
      pending ? ENV["NAVISHAI_MEMORY_PENDING"] = pending : ENV.delete("NAVISHAI_MEMORY_PENDING")
      yield
    ensure
      keys.each { |key| original.key?(key) ? ENV[key] = original[key] : ENV.delete(key) }
    end
end
