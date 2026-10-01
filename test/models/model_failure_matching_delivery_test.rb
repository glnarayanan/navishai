require "test_helper"
require_relative "../test_helpers/model_failure_matching_test_helper"

class ModelFailureMatchingDeliveryTest < ActiveSupport::TestCase
  include ModelFailureMatchingTestHelper
  self.use_transactional_tests = false
  setup { @existing_audit_ids = AuditEvent.ids }
  teardown do
    @corpus&.delete
    ActiveRecord::Base.connection.disable_referential_integrity { AuditEvent.where.not(id: @existing_audit_ids).delete_all }
  end

  test "duplicate workers claim once outside database locks and purge discards the returning copy" do
    build_model_matching_fixture
    entered, release = Queue.new, Queue.new
    calls = 0
    worker = nil
    response = matching_response
    with_matching_approval do
      request = request_matching
      with_test_method(Resolv, :getaddresses, ->(*) { [ "93.184.216.34" ] }) do
        with_test_method(EvaluationHttp, :perform, ->(*) { calls += 1; entered << true; release.pop; response.to_json }) do
          worker = Thread.new { ActiveRecord::Base.connection_pool.with_connection { ModelFailureMatchingJob.perform_now(request.id) } }
          Timeout.timeout(5) { entered.pop }
          ModelFailureMatchingJob.perform_now(request.id)
          assert_equal "running", request.reload.state
          ActiveRecord::Base.transaction do
            ActiveRecord::Base.connection.execute("SET LOCAL lock_timeout = '1s'")
            @corpus.lock!
            @membership.lock!
            SourcePurge.call(source: @document.source_snapshot.source, membership: @membership)
          end
          release << true
          worker.value
        end
      end
      assert_equal 1, calls
      assert_not ModelFailureMatching.exists?(request.id)
      assert_empty ModelFailureMatchingResult.where(corpus: @corpus)
    end
  ensure
    release << true if release
    worker&.value
  end

  test "a claimed worker with unknown outcome does not send again and can only be stopped" do
    build_model_matching_fixture
    with_matching_approval do
      request = request_matching
      request.update!(state: "running", started_at: 11.minutes.ago)
      with_test_method(ModelFailureMatcher, :call, ->(*) { flunk "Unknown attempt retried" }) do
        2.times { ModelFailureMatchingJob.perform_now(request.id) }
        assert_equal request.id, request_matching.id
        request.interrupt!(membership: @membership)
        ModelFailureMatchingJob.perform_now(request.id)
      end
      assert_equal "interrupted", request.reload.state
      assert_nil request.model_failure_matching_result
      assert_equal({}, AuditEvent.where(action: "trace.matching_interrupted").last.metadata)
    end
  end
end
