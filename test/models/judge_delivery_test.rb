require "test_helper"
require_relative "../test_helpers/judge_test_helper"

class JudgeDeliveryTest < ActiveSupport::TestCase
  include JudgeTestHelper
  self.use_transactional_tests = false
  setup { @existing_audit_ids = AuditEvent.ids }
  teardown do
    @corpus&.delete
    ActiveRecord::Base.connection.disable_referential_integrity { AuditEvent.where.not(id: @existing_audit_ids).delete_all }
  end

  test "concurrent calibration delivery sends once outside locks and expiry discards the response" do
    build_judge_evaluation
    sample = judge_sample
    entered, release = Queue.new, Queue.new
    calls = 0
    worker = nil
    with_endpoint_approval do
      run = CalibrationJudgeRun.request!(sample:, membership: @membership, disclose: true)
      with_test_method(JudgeGrader, :call, ->(**) { calls += 1; entered << true; release.pop; judge_response }) do
        worker = Thread.new { ActiveRecord::Base.connection_pool.with_connection { CalibrationJudgeRunJob.perform_now(run.id) } }
        Timeout.timeout(5) { entered.pop }
        ActiveRecord::Base.transaction do
          ActiveRecord::Base.connection.execute("SET LOCAL lock_timeout = '1s'")
          @corpus.lock!
          @membership.lock!
          @knowledge.source_snapshot.source.update!(expires_at: 1.second.ago)
        end
        CalibrationJudgeRunJob.perform_now(run.id)
        release << true
        worker.value
      end
      assert_equal 1, calls
      assert_equal "interrupted", run.reload.state
      assert_nil sample.reload.calibration_prediction
    end
  ensure
    release << true if release
    worker&.value
  end
end
