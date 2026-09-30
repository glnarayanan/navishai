require_relative "evaluation_test_helper"
require_relative "http_target_test_helper"

module JudgeTestHelper
  include EvaluationTestHelper
  include HttpTargetTestHelper

  def judge_execution
    { "endpoint" => HTTP_ENDPOINT, "model" => "test-judge-2026-09", "settings" => { "temperature" => 0, "max_output_tokens" => 1024, "seed" => 17 } }
  end

  def build_judge_evaluation
    build_eval_definitions
    with_endpoint_approval do
      @outcome_grader.revise!(membership: @membership, version_id: @outcome_grader.current_version_id, kind: "rubric_judge", definition: @outcome_grader.current_version.definition.merge("execution" => judge_execution))
    end
    @checks.each { |check| check["grader_version_id"] = @outcome_grader.current_version_id unless check["requirement_kind"] == "actions" }
    @case = compile_case
    @judge_check = @case.eval_case_checks.find_by!(requirement_kind: "outcomes")
    @suite = @corpus.eval_suites.create!(workspace: @workspace, name: "Calibrated diagnosis")
    @suite.add_case!(membership: @membership, case_id: @case.id)
    @target = EvaluationTarget.define!(corpus: @corpus, membership: @membership, name: "Recorded support fixture", configuration: script_configuration(output: support_output(tools: [ "collect_expiry" ])))
    @judge_set = CalibrationSet.define!(corpus: @corpus, membership: @membership, name: "Diagnosis agreement", grader_version_id: @outcome_grader.current_version_id)
  end

  def judge_sample(output: support_output(tools: [ "collect_expiry" ]), cohort: "held_out")
    @judge_set.add_sample!(membership: @membership, check_id: @judge_check.id, cohort:, output:)
  end

  def judge_response(output: support_output(tools: [ "collect_expiry" ]), decision: "fail", confidence: 0.9)
    { "schema" => "support-judge-v1", "model" => "test-judge-2026-09", "decision" => decision,
      "reason" => "The output requests evidence but never identifies the possible cause.", "confidence" => confidence,
      "quotes" => [ { "reference" => "company_evidence", "quote" => @judge_check.scenario_evidence.excerpt }, { "reference" => "target_output", "quote" => output.fetch("messages").first.fetch("content") } ],
      "usage" => { "input_tokens" => 300, "output_tokens" => 70 }, "cost" => { "currency" => "USD", "micro_units" => 27 } }
  end

  def with_judge_response(response:, calls: [])
    with_endpoint_approval do
      with_test_method(Resolv, :getaddresses, ->(*) { [ "93.184.216.34" ] }) do
        with_test_method(EvaluationHttp, :perform, ->(_uri, request, _address) { calls << request; response.to_json }) { yield }
      end
    end
  end
end
