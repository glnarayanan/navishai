require "test_helper"
require_relative "../test_helpers/failure_patterns_test_helper"

class EvaluationFailurePatternsTest < ActiveSupport::TestCase
  include FailurePatternsTestHelper

  setup { build_failure_patterns }

  test "patterns span graders and retain every exact check instead of counting cases or grader identities" do
    groups = EvaluationFailurePatterns.call(items: pattern_items)
    assert_equal [ [ "outcomes", "rubric_judge" ], [ "actions", "tool_called" ], [ "forbidden", "forbidden_tool" ],
      [ "escalation", "escalation" ], [ "grounding", "citation_present" ] ], groups.keys
    actions = groups.fetch([ "actions", "tool_called" ])
    assert_equal 4, actions.size
    assert_equal [ @case.id, @other_case.id ], actions.map { |failure| failure[:item].eval_case_id }.uniq
    assert_equal [ @action_grader.current_version_id, @metadata_grader.current_version_id, @other_action_grader.current_version_id ].sort,
      actions.map { |failure| failure[:check].grader_version_id }.uniq.sort
    assert_equal [ "Collect expiry.", "Collect metadata." ], actions.map { |failure| failure[:check].requirement }.uniq
    assert_equal 12, groups.values.sum(&:size)
    groups.values.flatten.each do |failure|
      assert_equal failure[:check].id, failure[:decision]["check_id"]
      assert_equal failure[:check].grader_version_id, failure[:decision]["grader_version_id"]
      assert_equal "Request the certificate expiry date.", failure[:check].scenario_evidence.excerpt
    end
    assert_equal [ 0.94, 0.94 ], groups.fetch([ "outcomes", "rubric_judge" ]).map { |failure| failure[:decision]["confidence"] }
  end

  test "uncertain raw failures and errors never enter groups and decisions cannot choose another fixed binding or type" do
    items = pattern_items
    result = items.first.evaluation_result
    original = result.decisions.deep_dup
    assert_equal %w[fail abstain error], original.select { |entry| entry["grader_version_id"] == @outcome_grader.current_version_id }.map { |entry| entry["decision"] }
    assert_equal "fail", original.find { |entry| entry["decision"] == "abstain" }["raw_decision"]
    assert_no_difference [ "EvaluationResult.count", "AuditEvent.count", "RegressionCase.count" ] do
      groups = EvaluationFailurePatterns.call(items:)
      assert_equal 12, groups.values.sum(&:size)
      assert_equal original, result.decisions
    end
    tool = result.decisions.find { |entry| entry["grader_version_id"] == @action_grader.current_version_id }
    tool["check_type"] = "escalation"
    assert_equal 4, EvaluationFailurePatterns.call(items:).fetch([ "actions", "tool_called" ]).size
    tool["check_id"] = @other_case.eval_case_checks.find_by!(requirement_kind: "actions", requirement_index: 0).id
    assert_equal 3, EvaluationFailurePatterns.call(items:).fetch([ "actions", "tool_called" ]).size
    result.status = "error"
    assert_equal 6, EvaluationFailurePatterns.call(items:).values.sum(&:size)
  end

  test "queued incomplete and execution error results are not failure patterns" do
    queued = request_run
    assert_empty EvaluationFailurePatterns.call(items: pattern_items(queued))
    output = support_output(tools: [ "collect_expiry", "collect_metadata" ]).merge(
      "escalation" => { "triggered" => true, "team" => "Engineering" },
      "citations" => [ { "reference" => "corpus-item-#{@knowledge.id}", "quote" => "Request the certificate expiry date." } ])
    @target.revise!(membership: @membership, version_id: @target.current_version_id, configuration: script_configuration(output:))
    incomplete = request_run
    EvaluationRunJob.perform_now(incomplete.id)
    assert_equal [ "incomplete", "incomplete" ], incomplete.evaluation_results.order(:id).pluck(:status)
    assert_empty EvaluationFailurePatterns.call(items: pattern_items(incomplete))
    error_run = request_run
    with_scripted_call(->(**) { {} }) { EvaluationRunJob.perform_now(error_run.id) }
    assert_equal [ "error", "error" ], error_run.evaluation_results.order(:id).pluck(:status)
    assert_empty EvaluationFailurePatterns.call(items: pattern_items(error_run))
  end
end
