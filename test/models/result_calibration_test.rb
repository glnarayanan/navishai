require "test_helper"
require_relative "../test_helpers/evaluation_test_helper"
require_relative "../../db/migrate/20261001040000_bind_calibration_samples_to_saved_results"

class ResultCalibrationTest < ActiveSupport::TestCase
  include EvaluationTestHelper
  setup do
    build_evaluation
    @run = request_run
    EvaluationRunJob.perform_now(@run.id)
    @result = @run.evaluation_results.sole
    @check = @case.eval_case_checks.find_by!(requirement_kind: "actions")
    @set = CalibrationSet.define!(corpus: @corpus, membership: @membership, name: "Selected failures", grader_version_id: @action_grader.current_version_id)
  end

  test "retained output wins over forged output and provenance and cohort cannot be overwritten" do
    sample = seed(output: support_output(tools: [ "collect_expiry" ]))
    assert_equal @result.output, sample.output
    assert_equal @result, sample.evaluation_result
    assert_equal @case, sample.eval_case
    assert_equal "fail", sample.calibration_prediction.result["decision"]
    assert_empty sample.human_labels
    assert_nil sample.calibration_judge_run
    assert_no_difference "CalibrationSample.count" do
      assert_equal sample, seed
      assert_raises(EvalCase::Invalid) { seed(cohort: "held_out") }
      assert_raises(EvalCase::Invalid) { @set.add_sample!(membership: @membership, check_id: @check.id, cohort: "development", output: @result.output) }
      run = request_run
      EvaluationRunJob.perform_now(run.id)
      assert_raises(EvalCase::Invalid) { seed(evaluation_result_id: run.evaluation_results.sole.id) }
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      CalibrationSample.transaction(requires_new: true) { CalibrationSample.where(id: sample.id).update_all(evaluation_result_id: nil) }
    end
  end

  test "manual provenance conflict and missing cohort refuse rather than relabel" do
    assert_raises(ActiveRecord::RecordInvalid) { seed(cohort: "") }
    manual = @set.add_sample!(membership: @membership, check_id: @check.id, cohort: "development", output: @result.output)
    assert_raises(EvalCase::Invalid) { seed }
    assert_nil manual.reload.evaluation_result_id
  end

  test "fixed case grader version and scoped result are required including SQL case binding" do
    other_case = compile_case(checks: @checks.map { |binding| binding.merge("grader_version_id" => @action_grader.current_version_id) })
    other_check = other_case.eval_case_checks.find_by!(requirement_kind: "actions")
    assert_raises(EvalCase::Invalid) { seed(check_id: other_check.id) }
    assert_raises(ActiveRecord::RecordNotFound) { seed(check_id: @case.eval_case_checks.find_by!(requirement_kind: "outcomes").id) }
    assert_raises(ActiveRecord::RecordNotFound) { seed(evaluation_result_id: -1) }
    @action_grader.revise!(membership: @membership, version_id: @action_grader.current_version_id, kind: "deterministic", definition: { "type" => "tool_called", "value" => "other" })
    revised = CalibrationSet.define!(corpus: @corpus, membership: @membership, name: "New grader", grader_version_id: @action_grader.current_version_id)
    assert_raises(ActiveRecord::RecordNotFound) { revised.add_sample!(membership: @membership, check_id: @check.id, cohort: "development", evaluation_result_id: @result.id) }
    sample = seed
    attributes = sample.attributes.except("id").merge("output_digest" => "sql-test")
    [ { "eval_case_id" => other_case.id }, { "eval_case_check_id" => other_check.id }, { "eval_case_id" => other_case.id, "eval_case_check_id" => other_check.id }, { "workspace_id" => workspaces(:beta_support).id } ].each do |mismatch|
      assert_raises(ActiveRecord::InvalidForeignKey) do
        CalibrationSample.transaction(requires_new: true) { CalibrationSample.insert_all!([ attributes.merge(mismatch) ]) }
      end
    end
  end

  test "errors revoked access rejected stale and expired definitions block import and purge removes provenance" do
    run = request_run
    with_scripted_call(->(**) { {} }) { EvaluationRunJob.perform_now(run.id) }
    assert_raises(EvalCase::Invalid) { seed(evaluation_result_id: run.evaluation_results.sole.id) }
    Membership.create!(workspace: @workspace, user: users(:teammate), role: :owner)
    @membership.update!(role: :viewer)
    assert_raises(Current::RoleAccessDenied) { seed }
    @membership.update!(role: :owner)
    @scenario.review!(membership: @membership, version_id: @scenario.current_version_id, decision: "reject")
    assert_raises(EvalCase::Invalid) { seed }
    @scenario.review!(membership: @membership, version_id: @scenario.current_version_id, decision: "approve")
    sample = seed
    @knowledge.source_snapshot.source.update!(expires_at: 1.second.ago)
    assert_raises(EvalCase::Invalid) { seed }
    SourcePurge.call(source: @knowledge.source_snapshot.source, membership: @membership)
    assert_not CalibrationSample.exists?(sample.id)
    assert_not EvaluationResult.exists?(@result.id)
  end

  test "stale scenario foreign saved result and a full cohort are refused" do
    original_set, original_check, original_membership = @set, @check, @membership
    build_evaluation
    run = request_run
    EvaluationRunJob.perform_now(run.id)
    assert_raises(ActiveRecord::RecordNotFound) do
      original_set.add_sample!(membership: original_membership, check_id: original_check.id, cohort: "development", evaluation_result_id: run.evaluation_results.sole.id)
    end
    100.times do |index|
      original_set.add_sample!(membership: original_membership, check_id: original_check.id, cohort: "development", output: support_output(text: "Bound #{index}"))
    end
    assert_raises(EvalCase::Invalid) do
      original_set.add_sample!(membership: original_membership, check_id: original_check.id, cohort: "development", evaluation_result_id: @result.id)
    end
    @scenario.revise!(membership: @membership, base_version_id: @scenario.current_version_id, attributes: { situation: "A revised situation" })
    assert_raises(EvalCase::Invalid) { @case.eligible! }
    new_set = CalibrationSet.define!(corpus: @corpus, membership: @membership, name: "Stale import", grader_version_id: @action_grader.current_version_id)
    assert_raises(EvalCase::Invalid) do
      new_set.add_sample!(membership: @membership, check_id: @case.eval_case_checks.find_by!(requirement_kind: "actions").id, cohort: "development", evaluation_result_id: run.evaluation_results.sole.id)
    end
  end

  test "migration backfills manual cases without rewriting outputs cohorts predictions or label history" do
    sample = @set.add_sample!(membership: @membership, check_id: @check.id, cohort: "held_out", output: @result.output)
    label = sample.label!(membership: @membership, previous_id: nil, decision: "fail", rationale: "Keep original history.")
    original = sample.attributes.except("eval_case_id", "evaluation_result_id")
    migration = BindCalibrationSamplesToSavedResults.new
    ActiveRecord::Migration.suppress_messages do
      migration.migrate(:down)
      migration.migrate(:up)
    end
    assert_equal original, sample.reload.attributes.except("eval_case_id", "evaluation_result_id")
    assert_equal @case.id, sample.eval_case_id
    assert_nil sample.evaluation_result_id
    assert_equal label, sample.human_labels.sole
    assert_equal "fail", sample.calibration_prediction.result["decision"]
    assert_raises(ActiveRecord::StatementInvalid) do
      CalibrationSample.transaction(requires_new: true) { CalibrationSample.where(id: sample.id).update_all(evaluation_result_id: @result.id) }
    end
  end

  private
    def seed(**options)
      @set.add_sample!(membership: @membership, check_id: @check.id, cohort: "development", evaluation_result_id: @result.id, **options)
    end
end
