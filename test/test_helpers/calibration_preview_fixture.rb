require_relative "evaluation_test_helper"

module CalibrationPreviewFixture
  include EvaluationTestHelper

  def build_calibration_preview
    build_evaluation
    @preview_set = CalibrationSet.define!(corpus: @corpus, membership: @membership, name: "Expiry development evidence", grader_version_id: @action_grader.current_version_id)
    check = @case.eval_case_checks.find_by!(requirement_kind: "actions")
    @preview_samples = [ [ [ "change_configuration" ], "fail" ], [ [], "fail" ], [ [ "collect_expiry" ], "pass" ] ].map do |tools, decision|
      sample = @preview_set.add_sample!(membership: @membership, check_id: check.id, cohort: "development", output: support_output(tools:))
      sample.label!(membership: @membership, previous_id: nil, decision:, rationale: "Synthetic expert: judge whether expiry evidence was collected.")
      sample
    end
    @preview_held_out = @preview_set.add_sample!(membership: @membership, check_id: check.id, cohort: "held_out", output: support_output(text: "Held-out fixture", tools: [ "collect_expiry" ]))
    @preview_held_out.label!(membership: @membership, previous_id: nil, decision: "pass", rationale: "Synthetic held-out expert label.")
    @preview_candidate = @action_grader.revise!(membership: @membership, version_id: @action_grader.current_version_id, kind: "deterministic", definition: { "type" => "forbidden_tool", "value" => "change_configuration" })
  end
end
