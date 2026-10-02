require "test_helper"
require_relative "../test_helpers/judge_test_helper"

class JudgeExecutionTest < ActiveSupport::TestCase
  include JudgeTestHelper
  setup { build_judge_evaluation }

  test "calibration consent binds a once claimed attempt and never overwrites labels or predictions" do
    sample = judge_sample
    label = sample.label!(membership: @membership, previous_id: nil, decision: "pass", rationale: "Expert intentionally disagrees with the judge.")
    with_endpoint_approval do
      assert_no_difference "CalibrationJudgeRun.count" do
        [ false, "true", nil ].each { |disclose| assert_raises(EvalCase::Invalid) { CalibrationJudgeRun.request!(sample:, membership: @membership, disclose:) } }
        assert_raises(Current::RoleAccessDenied) { CalibrationJudgeRun.request!(sample:, membership: memberships(:outsider_beta), disclose: true) }
      end
      run = CalibrationJudgeRun.request!(sample:, membership: @membership, disclose: true)
      assert_equal run, CalibrationJudgeRun.request!(sample:, membership: @membership, disclose: true)
      calls = []
      with_judge_response(response: judge_response, calls:) { 2.times { CalibrationJudgeRunJob.perform_now(run.id) } }
      assert_equal 1, calls.size
      assert_equal run.request_key, calls.sole["Idempotency-Key"]
      assert_equal "complete", run.reload.state
      prediction = sample.reload.calibration_prediction
      assert_equal "fail", prediction.result["decision"]
      assert_equal [ label ], sample.latest_labels.to_a
      assert_equal 1, CalibrationReport.call(set: @judge_set)[:false_positive]
      assert_raises(ActiveRecord::StatementInvalid) { CalibrationJudgeRun.transaction(requires_new: true) { CalibrationJudgeRun.where(id: run.id).update_all(request_key: SecureRandom.uuid) } }
      assert_raises(ActiveRecord::StatementInvalid) { CalibrationPrediction.transaction(requires_new: true) { CalibrationPrediction.where(id: prediction.id).update_all(result: { decision: "pass" }) } }
      other_sample = judge_sample(output: support_output(text: "Separate fixed sample"))
      attributes = run.attributes.except("id", "request_key").merge("calibration_sample_id" => other_sample.id, "workspace_id" => workspaces(:beta_support).id)
      assert_raises(ActiveRecord::InvalidForeignKey) { CalibrationJudgeRun.transaction(requires_new: true) { CalibrationJudgeRun.create!(attributes) } }
      SourcePurge.call(source: @knowledge.source_snapshot.source, membership: @membership)
      assert_not CalibrationJudgeRun.exists?(run.id)
      assert_not CalibrationPrediction.exists?(prediction.id)
    end
  end

  test "revoked access and changed evidence stop a calibration attempt without a prediction or retry" do
    sample = judge_sample
    with_endpoint_approval do
      run = CalibrationJudgeRun.request!(sample:, membership: @membership, disclose: true)
      Membership.create!(workspace: @workspace, user: users(:teammate), role: :owner)
      @membership.update!(role: :viewer)
      with_test_method(EvaluationHttp, :call, ->(**) { flunk "Revoked access cannot disclose" }) { CalibrationJudgeRunJob.perform_now(run.id) }
      assert_equal "interrupted", run.reload.state
      assert_nil sample.reload.calibration_prediction
      @membership.update!(role: :owner)
      other = judge_sample(output: support_output(text: "Second recorded output"))
      other_run = CalibrationJudgeRun.request!(sample: other, membership: @membership, disclose: true)
      with_test_method(JudgeGrader, :call, ->(**) { @knowledge.source_snapshot.source.update!(expires_at: 1.second.ago); { "decision" => "pass" } }) do
        CalibrationJudgeRunJob.perform_now(other_run.id)
      end
      assert_equal "interrupted", other_run.reload.state
      assert_nil other.reload.calibration_prediction
      with_test_method(EvaluationHttp, :call, ->(**) { flunk "Interrupted attempts cannot retry" }) { [ run, other_run ].each { |record| CalibrationJudgeRunJob.perform_now(record.id) } }
    end
  end

  test "unknown calibration outcomes stay errors and old running attempts can be stopped deliberately" do
    sample = judge_sample
    with_judge_response(response: {}) do
      run = CalibrationJudgeRun.request!(sample:, membership: @membership, disclose: true)
      CalibrationJudgeRunJob.perform_now(run.id)
      assert_equal "error", sample.reload.calibration_prediction.result["decision"]
      sample.label!(membership: @membership, previous_id: nil, decision: "fail", rationale: "Missing diagnosis.")
      assert_equal 0, CalibrationReport.call(set: @judge_set)[:compared]
      assert_nil CalibrationReport.call(set: @judge_set)[:precision]
    end
    with_endpoint_approval do
      other = judge_sample(output: support_output(text: "Interrupted fixture"))
      run = CalibrationJudgeRun.request!(sample: other, membership: @membership, disclose: true)
      run.update!(state: "running", started_at: Time.current)
      assert_raises(EvalCase::Invalid) { run.interrupt!(membership: @membership) }
      run.update!(started_at: 11.minutes.ago)
      run.interrupt!(membership: @membership)
      assert_equal "interrupted", run.reload.state
      with_test_method(EvaluationHttp, :call, ->(**) { flunk "Manual interruption prevents dispatch" }) { CalibrationJudgeRunJob.perform_now(run.id) }
    end
  end

  test "suite judge consent is separate from target consent and freezes each check attempt and grader" do
    with_endpoint_approval do
      target = define_http_target
      assert_no_difference "EvaluationRun.count" do
        assert_raises(EvalCase::Invalid) { EvaluationRun.request!(suite: @suite, membership: @membership, target_version_id: target.current_version_id, disclose: true) }
        assert_raises(EvalCase::Invalid) { EvaluationRun.request!(suite: @suite, membership: @membership, target_version_id: target.current_version_id, disclose: true, judge_disclose: "true") }
        assert_raises(EvalCase::Invalid) { EvaluationRun.request!(suite: @suite, membership: @membership, target_version_id: target.current_version_id, judge_disclose: true) }
      end
      run = EvaluationRun.request!(suite: @suite, membership: @membership, target_version_id: @target.current_version_id, judge_disclose: true, suite_digest: Digest::SHA256.hexdigest([ @case.id ].to_json))
      assert run.judge_disclosure
      assert_raises(ActiveRecord::StatementInvalid) { EvaluationRun.transaction(requires_new: true) { EvaluationRun.where(id: run.id).update_all(judge_disclosure: false) } }
      version = @outcome_grader.current_version
      @outcome_grader.revise!(membership: @membership, version_id: version.id, kind: "rubric_judge", definition: version.definition.merge("rubric" => "New rubric, not this run."))
      calls = []
      with_judge_response(response: judge_response, calls:) { 2.times { EvaluationRunJob.perform_now(run.id) } }
      assert_equal 1, calls.size
      assert_equal version.definition["rubric"], JSON.parse(calls.sole.body)["rubric"]
      result = run.evaluation_results.sole
      assert_equal "fail", result.status
      decision = result.decisions.find { |entry| entry["grader_version_id"] == version.id }
      assert_equal "fail", decision["decision"]
      assert_equal decision["request_key"], calls.sole["Idempotency-Key"]
      assert_equal 64, decision["request_key"].length
      assert_equal "pass", result.decisions.find { |entry| entry["grader_version_id"] == @action_grader.current_version_id }["decision"]
    end
  end

  test "judge errors and abstention keep target output but cannot become passing or regression results" do
    [ {}, judge_response(confidence: 0.79) ].each do |response|
      with_judge_response(response:) do
        run = EvaluationRun.request!(suite: @suite, membership: @membership, target_version_id: @target.current_version_id, judge_disclose: true, suite_digest: Digest::SHA256.hexdigest([ @case.id ].to_json))
        EvaluationRunJob.perform_now(run.id)
        result = run.evaluation_results.sole
        assert_equal "incomplete", result.status
        assert_equal support_output(tools: [ "collect_expiry" ]), result.output
        regression = @corpus.eval_suites.create!(workspace: @workspace, name: "Not a behavioural failure", kind: "regression")
        assert_raises(EvalCase::Invalid) { result.add_regression!(membership: @membership, suite_id: regression.id, rationale: "Unknown judgment cannot be a failure.") }
      end
    end
    with_endpoint_approval do
      run = EvaluationRun.request!(suite: @suite, membership: @membership, target_version_id: @target.current_version_id, judge_disclose: true, suite_digest: Digest::SHA256.hexdigest([ @case.id ].to_json))
      ENV["NAVISHAI_EVALUATION_ENDPOINTS"] = "[]"
      with_test_method(EvaluationHttp, :perform, ->(*) { flunk "Revoked endpoint cannot receive judge data" }) { EvaluationRunJob.perform_now(run.id) }
      assert_equal "incomplete", run.evaluation_results.sole.status
      assert_equal "error", run.evaluation_results.sole.decisions.find { |entry| entry["check_id"] == @judge_check.id }["decision"]
    end
  end

  test "changed suite membership cannot expand a prior judge disclosure confirmation" do
    digest = Digest::SHA256.hexdigest([ @case.id ].to_json)
    other_checks = @checks.map { |check| check.merge("grader_version_id" => @outcome_grader.current_version_id) }
    @suite.add_case!(membership: @membership, case_id: compile_case(checks: other_checks).id)
    with_endpoint_approval do
      assert_no_difference "EvaluationRun.count" do
        error = assert_raises(EvalCase::Invalid) { EvaluationRun.request!(suite: @suite, membership: @membership, target_version_id: @target.current_version_id, judge_disclose: true, suite_digest: digest) }
        assert_includes error.message, "Suite membership changed"
      end
    end
  end
end
