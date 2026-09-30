require "test_helper"
require_relative "../test_helpers/evaluation_test_helper"

class EvaluationDeliveryTest < ActiveSupport::TestCase
  include EvaluationTestHelper
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
end
