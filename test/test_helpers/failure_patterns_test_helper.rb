require_relative "evaluation_test_helper"

module FailurePatternsTestHelper
  include EvaluationTestHelper

  def build_failure_patterns
    build_evaluation
    @scenario.revise!(membership: @membership, base_version_id: @scenario.current_version_id, attributes: {
      importance: "critical", requirements: {
        outcomes: [ "Identify expiry as possible, not confirmed.", "Qualify incomplete diagnosis.", "Explain next evidence needed." ],
        actions: [ "Collect expiry.", "Collect metadata." ], forbidden: [ "Do not reset configuration." ],
        escalation: [ "Escalate ACS 500 to Engineering." ], grounding: [ "Cite the playbook." ]
      }
    })
    @scenario.review!(membership: @membership, version_id: @scenario.current_version_id, decision: "approve")
    @metadata_grader = Grader.define!(corpus: @corpus, membership: @membership, name: "Metadata evidence", kind: "deterministic", definition: { "type" => "tool_called", "value" => "collect_metadata" })
    @other_action_grader = Grader.define!(corpus: @corpus, membership: @membership, name: "Expiry check from another grader", kind: "deterministic", definition: @action_grader.current_version.definition)
    @pattern_graders = {
      "forbidden" => Grader.define!(corpus: @corpus, membership: @membership, name: "No reset", kind: "deterministic", definition: { "type" => "forbidden_tool", "value" => "reset_configuration" }),
      "escalation" => Grader.define!(corpus: @corpus, membership: @membership, name: "Engineering handoff", kind: "deterministic", definition: { "type" => "escalation", "value" => "Engineering" }),
      "grounding" => Grader.define!(corpus: @corpus, membership: @membership, name: "Company citation", kind: "deterministic", definition: { "type" => "citation_present", "value" => "corpus-item-#{@knowledge.id}" })
    }
    @checks = @scenario.current_version.requirements.flat_map do |kind, statements|
      statements.each_index.map do |index|
        grader = kind == "outcomes" ? @outcome_grader : kind == "actions" ? (index == 0 ? @action_grader : @metadata_grader) : @pattern_graders.fetch(kind)
        { "requirement_kind" => kind, "requirement_index" => index, "grader_version_id" => grader.current_version_id,
          "scenario_evidence_id" => @scenario.current_version.scenario_evidence.find_by!(kind: "knowledge").id }
      end
    end
    @case = compile_case
    @other_case = compile_case(checks: @checks.map { |check| check["requirement_kind"] == "actions" && check["requirement_index"] == 0 ? check.merge("grader_version_id" => @other_action_grader.current_version_id) : check })
    @suite.eval_suite_cases.delete_all(:delete_all)
    [ @case, @other_case ].each { |item| @suite.add_case!(membership: @membership, case_id: item.id) }
    @target.revise!(membership: @membership, version_id: @target.current_version_id, configuration: script_configuration(output: support_output(tools: [ "reset_configuration" ])))
    @mixed_run = request_run(judge_disclose: true)
    original = JudgeGrader.method(:call)
    JudgeGrader.define_singleton_method(:call) do |check:, **|
      case check.requirement_index
      when 0
        { "decision" => "fail", "reason" => "Unsupported certainty in the saved reply.", "confidence" => 0.94,
          "raw_decision" => "fail", "quotes" => [ { "reference" => "company_evidence", "quote" => "Request the certificate expiry date." },
            { "reference" => "target_output", "quote" => "Please share the certificate expiry date." } ] }
      when 1
        { "decision" => "abstain", "raw_decision" => "fail", "reason" => "Below the fixed threshold.", "confidence" => 0.32 }
      when 2
        { "decision" => "error", "reason" => "Judge request failed; remote outcome unknown.", "confidence" => nil }
      end
    end
    EvaluationRunJob.perform_now(@mixed_run.id)
  ensure
    JudgeGrader.define_singleton_method(:call, original) if original
  end

  def pattern_items(run = @mixed_run)
    run.evaluation_run_items.order(:id).includes(:evaluation_result, eval_case: { eval_case_checks: :grader_version }).to_a
  end
end
