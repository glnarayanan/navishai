class EvaluationFailurePatterns
  CHECK_LABELS = {
    "tool_called" => "Required tool not reported",
    "forbidden_tool" => "Forbidden tool reported",
    "field_collected" => "Required field not reported",
    "citation_present" => "Required exact citation check unmet",
    "escalation" => "Required escalation not reported",
    "policy_branch" => "Required policy branch not reported",
    "text_contains" => "Required assistant text not found",
    "text_absent" => "Forbidden assistant text found",
    "tool_before" => "Required tool order not reported",
    "assistant_response_contains" => "Required reply text not found at every matching turn",
    "assistant_response_absent" => "Forbidden reply text or missing anchored reply",
    "rubric_judge" => "Requirement judged unmet"
  }.freeze

  def self.call(items:)
    failures = items.flat_map do |item|
      result = item.evaluation_result
      next [] unless result&.status == "fail"

      checks = item.eval_case.eval_case_checks.index_by(&:id)
      result.decisions.filter_map do |decision|
        next unless decision["decision"] == "fail"
        check = checks[decision["check_id"]]
        next unless check && check.grader_version_id == decision["grader_version_id"]

        { item:, check:, decision: }
      end
    end
    failures.group_by do |failure|
      check = failure.fetch(:check)
      type = check.grader_version.kind == "deterministic" ? check.grader_version.definition.fetch("type") : "rubric_judge"
      [ check.requirement_kind, type ]
    end.sort_by { |(kind, type), _| [ ScenarioVersion::REQUIREMENT_TYPES.index(kind), type ] }.to_h
  end
end
