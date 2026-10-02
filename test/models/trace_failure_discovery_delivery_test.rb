require "test_helper"
require_relative "../test_helpers/trace_failure_discovery_test_helper"

class TraceFailureDiscoveryDeliveryTest < ActiveSupport::TestCase
  include TraceFailureDiscoveryTestHelper
  self.use_transactional_tests = false
  setup { @existing_audit_ids = AuditEvent.ids; build_trace_discovery }
  teardown do
    @corpus&.delete
    ActiveRecord::Base.connection.disable_referential_integrity { AuditEvent.where.not(id: @existing_audit_ids).delete_all }
  end

  test "concurrent delivery claims once releases locks and discards response after purge" do
    entered, release = Queue.new, Queue.new
    calls = 0
    worker = nil
    with_trace_discovery_approval do
      discovery = request_trace_discovery
      response = trace_discovery_response
      with_test_method(EvaluationHttp, :call, ->(**) { calls += 1; entered << true; release.pop; response }) do
        worker = Thread.new { ActiveRecord::Base.connection_pool.with_connection { TraceFailureDiscoveryJob.perform_now(discovery.id) } }
        Timeout.timeout(5) { entered.pop }
        TraceFailureDiscoveryJob.perform_now(discovery.id)
        ActiveRecord::Base.transaction do
          ActiveRecord::Base.connection.execute("SET LOCAL lock_timeout = '1s'")
          @corpus.lock!
          @membership.lock!
          SourcePurge.call(source: @document.source_snapshot.source, membership: @membership)
        end
        release << true
        worker.value
      end
      assert_equal 1, calls
      assert_not TraceFailureDiscovery.exists?(discovery.id)
      assert_empty TraceFailureDiscoveryResult.where(corpus: @corpus)
    end
  ensure
    release << true if release
    worker&.value
  end

  test "revoked membership endpoint expiry and changed comparison set discard unlocked responses with no retry" do
    changes = [
      -> { @membership.update!(role: "viewer") },
      -> { ENV["NAVISHAI_TRACE_DISCOVERY_ENDPOINTS"] = "[]" },
      -> { @document.source_snapshot.source.update!(expires_at: 1.second.ago) },
      -> { @scenario.revise!(membership: @membership, base_version_id: @scenario.current_version_id, attributes: { situation: "Changed starting situation" }) }
    ]
    changes.each_with_index do |change, index|
      @document.source_snapshot.source.update!(expires_at: 30.days.from_now)
      @membership.update!(role: "owner")
      with_trace_discovery_approval do
        discovery = request_trace_discovery
        response = trace_discovery_response
        calls = 0
        with_test_method(EvaluationHttp, :call, ->(**) { calls += 1; change.call; response }) do
          2.times { TraceFailureDiscoveryJob.perform_now(discovery.id) }
        end
        assert_equal 1, calls, "Change #{index}"
        assert_equal "interrupted", discovery.reload.state
        assert_nil discovery.trace_failure_discovery_result
        assert_equal 1, @corpus.scenarios.count
        assert_equal 0, HumanLabel.where(corpus: @corpus).count
      end
    end
  end

  test "queued cancellation and old crashed claims cannot send on repeated job delivery" do
    with_trace_discovery_approval do
      queued = request_trace_discovery
      queued.interrupt!(membership: @membership)
      running = request_trace_discovery
      running.update!(state: "running", started_at: 11.minutes.ago)
      calls = []
      with_trace_discovery_response(calls:) do
        TraceFailureDiscoveryJob.perform_now(queued.id)
        TraceFailureDiscoveryJob.perform_now(running.id)
        running.interrupt!(membership: @membership)
        TraceFailureDiscoveryJob.perform_now(running.id)
      end
      assert_empty calls
      assert_nil queued.reload.trace_failure_discovery_result
      assert_nil running.reload.trace_failure_discovery_result
      assert_equal "interrupted", running.state
    end
  end

  test "preview holds the corpus lock between aggregate checks and full reads" do
    entered, release = Queue.new, Queue.new
    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        owner = Thread.current
        observer = ->(event) do
          if Thread.current == owner && event.payload[:sql].match?(/SELECT COUNT\(\*\).*"corpus_items"/)
            entered << true
            release.pop
          end
        end
        ActiveSupport::Notifications.subscribed(observer, "sql.active_record") { trace_discovery_input }
      end
    end
    Timeout.timeout(5) { entered.pop }
    assert_raises(ActiveRecord::LockWaitTimeout) do
      ApplicationRecord.transaction(requires_new: true) { ApplicationRecord.connection.execute("SELECT id FROM corpora WHERE id = #{@corpus.id} FOR UPDATE NOWAIT") }
    end
    # Only the first count needs to pause; release every bounded count made by build.
    10.times { release << true }
    assert_equal @items.values.map(&:id).sort, worker.value.fetch("traces").pluck("id")
  ensure
    10.times { release << true } if release
    worker&.value
  end
end
