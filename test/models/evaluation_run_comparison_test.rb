require "test_helper"
require_relative "../test_helpers/evaluation_test_helper"

class EvaluationRunComparisonTest < ActiveSupport::TestCase
  include EvaluationTestHelper
  setup { build_evaluation }

  test "directional transitions retain exact items and preload inspection associations without writes" do
    { [ "pass", "fail" ] => "regression", [ "fail", "pass" ] => "recovery",
      [ "pass", "pass" ] => "unchanged_pass", [ "fail", "fail" ] => "unchanged_fail" }.each do |statuses, expected|
      before = comparison_run(status: statuses.first)
      after = comparison_run(status: statuses.last)
      assert_no_difference [ "EvaluationRun.count", "EvaluationRunItem.count", "EvaluationResult.count" ] do
        row = after.compare_with(baseline: before).sole
        assert_equal expected, row.fetch(:change)
        assert_equal before.evaluation_run_items.sole, row.fetch(:before)
        assert_equal after.evaluation_run_items.sole, row.fetch(:after)
        [ row[:before], row[:after] ].each do |item|
          assert item.association(:evaluation_result).loaded?
          assert item.association(:eval_case).loaded?
          assert item.eval_case.association(:scenario_version).loaded?
          assert item.eval_case.scenario_version.association(:scenario).loaded?
        end
      end
    end
  end

  test "same scenario and title with different frozen grader definitions are unmatched" do
    other = compile_case(checks: @checks.map { |check| check.merge("grader_version_id" => @action_grader.current_version_id) })
    assert_not_equal @case.id, other.id
    assert_equal @case.scenario_version_id, other.scenario_version_id
    before = comparison_run(status: "fail")
    after = comparison_run(status: "pass", eval_case: other)
    assert_unmatched before, after
  end

  test "nested object key order is equal but changed facts missing null false and zero are distinct" do
    input = { "situation" => "SSO", "known_facts" => { "count" => 0, "enabled" => false, "value" => nil }, "knowledge" => [] }
    reordered = { "knowledge" => [], "known_facts" => { "value" => nil, "enabled" => false, "count" => 0 }, "situation" => "SSO" }
    before = comparison_run(status: "fail", input:)
    assert_equal "recovery", comparison_run(status: "pass", input: reordered).compare_with(baseline: before).sole[:change]
    [ {}, { "value" => nil }, { "value" => false }, { "value" => 0 }, { "count" => 1, "enabled" => false, "value" => nil } ].each do |facts|
      assert_unmatched before, comparison_run(status: "pass", input: input.merge("known_facts" => facts))
    end
    [ nil, false, 0 ].combination(2).each do |left, right|
      assert_unmatched comparison_run(status: "fail", input: { "value" => left }), comparison_run(status: "pass", input: { "value" => right })
    end
    [ nil, false, 0 ].each do |value|
      assert_unmatched comparison_run(status: "fail", input: {}), comparison_run(status: "pass", input: { "value" => value })
    end
    assert_unmatched comparison_run(status: "fail", input: { "values" => [ 0, false ] }), comparison_run(status: "pass", input: { "values" => [ false, 0 ] })
  end

  test "missing error and incomplete outcomes are unresolved on either side" do
    [ nil, "error", "incomplete" ].each do |unknown|
      [ "pass", "fail", nil, "error", "incomplete" ].each do |known|
        before = comparison_run(status: unknown)
        after = comparison_run(status: known)
        assert_equal "unresolved", after.compare_with(baseline: before).sole[:change]
        assert_equal "unresolved", before.compare_with(baseline: after).sole[:change]
      end
    end
  end

  test "asymmetric membership includes before only after only and matched rows" do
    other = compile_case(checks: @checks.map { |check| check.merge("grader_version_id" => @action_grader.current_version_id) })
    before = comparison_run(status: "pass")
    after = comparison_run(status: "fail")
    removed = comparison_item(before, eval_case: other, input: { "only" => "before" }, status: "fail")
    added = comparison_item(after, eval_case: other, input: { "only" => "after" }, status: "pass")
    rows = after.compare_with(baseline: before)
    assert_equal 3, rows.size
    assert_equal [ "regression", "unmatched", "unmatched" ], rows.map { |row| row[:change] }
    assert_equal({ before: nil, after: added, change: "unmatched" }, rows[1])
    assert_equal({ before: removed, after: nil, change: "unmatched" }, rows[2])
  end

  test "self and another corpus are invalid and current expiry hides cached comparisons" do
    before = comparison_run(status: "fail")
    after = comparison_run(status: "pass")
    assert_raises(EvalCase::Invalid) { after.compare_with(baseline: after.reload) }
    foreign = @workspace.corpora.create!(name: "Separate corpus")
    suite = foreign.eval_suites.create!(workspace: @workspace, name: "Separate suite")
    target = EvaluationTarget.define!(corpus: foreign, membership: @membership, name: "Separate target", configuration: script_configuration)
    foreign_run = foreign.evaluation_runs.create!(workspace: @workspace, eval_suite: suite, evaluation_target_version: target.current_version,
      requested_by: @membership.user, processing_version: EvaluationRun::VERSION, created_at: Time.current)
    assert_raises(EvalCase::Invalid) { after.compare_with(baseline: foreign_run) }
    assert_raises(EvalCase::Invalid) { foreign_run.compare_with(baseline: after) }
    assert_equal "recovery", after.compare_with(baseline: before).sole[:change]
    after.corpus.sources.load
    @knowledge.source_snapshot.source.update!(expires_at: 1.second.ago)
    assert_raises(ActiveRecord::RecordNotFound) { after.compare_with(baseline: before) }
    assert_raises(ActiveRecord::RecordNotFound) { before.compare_with(baseline: after) }
  end

  private
    def comparison_run(status:, eval_case: @case, input: eval_case.scenario_version.target_input)
      run = @corpus.evaluation_runs.create!(workspace: @workspace, eval_suite: @suite, evaluation_target_version: @target.current_version,
        requested_by: @membership.user, processing_version: EvaluationRun::VERSION, created_at: Time.current)
      comparison_item(run, eval_case:, input:, status:)
      run
    end

    def comparison_item(run, eval_case:, input:, status:)
      item = run.evaluation_run_items.create!(workspace: @workspace, corpus: @corpus, eval_case:, target_input: input)
      item.create_evaluation_result!(workspace: @workspace, corpus: @corpus, eval_case:, status:, created_at: Time.current) if status
      item
    end

    def assert_unmatched(before, after)
      rows = after.compare_with(baseline: before)
      assert_equal [ "unmatched", "unmatched" ], rows.map { |row| row[:change] }
      assert_equal({ before: nil, after: after.evaluation_run_items.sole, change: "unmatched" }, rows.first)
      assert_equal({ before: before.evaluation_run_items.sole, after: nil, change: "unmatched" }, rows.last)
    end
end
