require "test_helper"
require_relative "../test_helpers/evaluation_test_helper"
require_relative "../test_helpers/http_target_test_helper"

class EvaluationDeliveryTest < ActiveSupport::TestCase
  include EvaluationTestHelper
  include HttpTargetTestHelper
  self.use_transactional_tests = false

  setup { @existing_audit_ids = AuditEvent.ids }

  teardown do
    @corpus&.delete
    ActiveRecord::Base.connection.disable_referential_integrity do
      AuditEvent.where.not(id: @existing_audit_ids).delete_all
    end
  end

  test "concurrent job delivery claims once and produces one result" do
    build_evaluation
    run = request_run
    barrier = Queue.new
    original = ScriptedTarget.method(:call)
    calls = 0
    mutex = Mutex.new
    with_scripted_call(->(**args) { mutex.synchronize { calls += 1 }; original.call(**args) }) do
      workers = 2.times.map do
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            barrier.pop
            EvaluationRunJob.perform_now(run.id)
          end
        end
      end
      2.times { barrier << true }
      workers.each(&:value)
    end
    assert_equal 1, calls
    assert_equal "complete", run.reload.state
    assert_equal 1, run.evaluation_results.count
    assert_equal 1, AuditEvent.where(subject_type: "EvaluationRun", subject_id: run.id, action: "evaluation.completed").count
  end

  test "HTTP waits outside database locks while duplicate delivery and concurrent expiry do not repeat or retain output" do
    build_evaluation
    other_checks = @checks.map { |check| check.merge("grader_version_id" => @outcome_grader.current_version_id) }
    @suite.add_case!(membership: @membership, case_id: compile_case(checks: other_checks).id)
    entered = Queue.new
    release = Queue.new
    calls = 0
    worker = nil
    with_endpoint_approval do
      target = define_http_target
      run = request_run(version: target.current_version, disclose: true)
      with_test_method(HttpTarget, :call, ->(**) { calls += 1; entered << true; release.pop; support_output }) do
        worker = Thread.new { ActiveRecord::Base.connection_pool.with_connection { EvaluationRunJob.perform_now(run.id) } }
        Timeout.timeout(5) { entered.pop }
        ActiveRecord::Base.transaction do
          ActiveRecord::Base.connection.execute("SET LOCAL lock_timeout = '1s'")
          @corpus.lock!
          @membership.lock!
          @knowledge.source_snapshot.source.update!(expires_at: 1.second.ago)
        end
        EvaluationRunJob.perform_now(run.id)
        release << true
        worker.value
      end
      assert_equal 1, calls
      assert_equal "interrupted", run.reload.state
      assert_empty run.evaluation_results
    end
  ensure
    release << true if release
    worker&.value
  end
end
