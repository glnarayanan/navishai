require_relative "scenario_test_helper"

module EvalTestHelper
  include ScenarioTestHelper

  def build_eval_definitions
    build_scenarios
    approve_scenario
    @scenario.revise!(membership: @membership, base_version_id: @scenario.current_version_id, attributes: { hidden_facts: { actual_cause: "private answer: expired certificate" } },
      evidence_item_id: @knowledge.id, evidence_kind: "knowledge", excerpt: "Request the certificate expiry date.")
    @scenario.review!(membership: @membership, version_id: @scenario.current_version_id, decision: "approve")
    @scenario.reload
    @action_grader = Grader.define!(corpus: @corpus, membership: @membership, name: "Collect expiry evidence", kind: "deterministic", definition: { "type" => "tool_called", "value" => "collect_expiry" })
    @outcome_grader = Grader.define!(corpus: @corpus, membership: @membership, name: "Certificate diagnosis", kind: "rubric_judge", definition: { "rubric" => "Pass when the assistant identifies certificate expiry as a possibility, not a confirmed diagnosis without evidence. Fail unsupported certainty or an unrelated diagnosis.", "confidence_threshold" => 0.8 })
    @checks = @scenario.current_version.requirements.flat_map do |kind, statements|
      statements.each_index.map { |index| { "requirement_kind" => kind, "requirement_index" => index, "grader_version_id" => (kind == "actions" ? @action_grader : @outcome_grader).current_version_id, "scenario_evidence_id" => @scenario.current_version.scenario_evidence.find_by!(kind: "expectation").id } }
    end
  end

  def compile_case(checks: @checks, version_id: @scenario.current_version_id)
    EvalCompiler.call(scenario: @scenario, membership: @membership, version_id:, checks:)
  end

  def support_output(text: "Please share the certificate expiry date.", tools: [])
    { "messages" => [ { "role" => "assistant", "content" => text } ], "tool_calls" => tools.map { |name| { "name" => name, "arguments" => {} } },
      "collected_fields" => {}, "citations" => [], "escalation" => { "triggered" => false, "team" => nil }, "policy_branch" => nil }
  end
end
