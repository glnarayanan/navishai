require "test_helper"
require_relative "../test_helpers/failure_patterns_test_helper"

class FailurePatternsAccessTest < ActionDispatch::IntegrationTest
  include FailurePatternsTestHelper

  setup do
    build_failure_patterns
    sign_in_as users(:owner)
  end

  test "read only patterns link exact fixed checks company evidence and individual judge uncertainty" do
    items = pattern_items
    assert_no_enqueued_jobs do
      assert_no_difference [ "EvaluationResult.count", "AuditEvent.count", "RegressionCase.count" ] do
        get workspace_corpus_evaluation_run_path(@workspace, @corpus, @mixed_run)
        assert_response :success
      end
    end
    assert_select "#failure-patterns[data-score]", count: 0
    assert_select "[data-pattern-kind]", count: 5
    assert_select "[data-pattern-kind=actions][data-pattern-type=tool_called]" do
      assert_select "p", text: "4 failed checks across 2 fixed cases · 3 grader versions."
      assert_select "[data-failed-check-id]", count: 4
    end
    assert_select "[data-failed-check-id]", count: 12
    assert_select "[data-unresolved-check-id]", count: 4
    items.each do |item|
      assert_select "a[href=?]", workspace_corpus_evaluation_result_path(@workspace, @corpus, item.evaluation_result), text: /Inspect failed result/
      assert_select "a[href=?]", workspace_corpus_eval_case_path(@workspace, @corpus, item.eval_case)
      check = item.eval_case.eval_case_checks.find_by!(requirement_kind: "outcomes", requirement_index: 0)
      assert_select "[data-failed-check-id='#{check.id}']" do
        assert_select "dd", text: /Identify expiry as possible, not confirmed/
        assert_select "dd", text: /0.94 · fixed abstention threshold 0.8/
        assert_select "pre", text: "Request the certificate expiry date."
        assert_select "a[href=?]", workspace_corpus_source_path(@workspace, @corpus, @knowledge.source_snapshot.source_id, snapshot: 1, page: 1, anchor: "record-#{@knowledge.id}"), text: /Source snapshot 1/
        assert_select "pre", text: /target_output/
      end
      abstain = item.eval_case.eval_case_checks.find_by!(requirement_kind: "outcomes", requirement_index: 1)
      assert_select "[data-unresolved-check-id='#{abstain.id}']" do
        assert_select "dd", text: /0.32 · fixed abstention threshold 0.8/
        assert_select "pre", text: /"raw_decision": "fail"/
      end
    end
    assert_select "#failure-patterns p", text: /Expert importance comes from the fixed scenario version/
    assert_select "#failure-patterns summary", text: /Critical importance/, count: 12
    assert_select "a[href=?]", workspace_corpus_scenario_path(@workspace, @corpus, @scenario, version: @case.scenario_version.number)
  end

  test "later expert and company revisions cannot relabel old failure checks or replace their source snapshot" do
    fixed_version = @case.scenario_version
    @scenario.revise!(membership: @membership, base_version_id: @scenario.current_version_id, attributes: { importance: "normal", title: "New unrelated title", requirements: fixed_version.requirements.merge("actions" => [ "New action" ]) })
    @outcome_grader.revise!(membership: @membership, version_id: @outcome_grader.current_version_id, kind: "rubric_judge", definition: { "rubric" => "New rubric", "confidence_threshold" => 0.99 })
    CorpusIntake.call(corpus: @corpus, membership: @membership, name: "SSO playbook", kind: "document", bytes: "New policy requiring unrelated evidence.")
    get workspace_corpus_evaluation_run_path(@workspace, @corpus, @mixed_run)
    assert_response :success
    assert_select "#failure-patterns summary", text: /Critical importance/, count: 12
    assert_select "#failure-patterns dd", text: /Collect expiry/
    assert_select "#failure-patterns dd", text: /fixed abstention threshold 0.8/
    assert_select "#failure-patterns dd", text: /fixed abstention threshold 0.99/, count: 0
    assert_select "#failure-patterns a[href=?]", workspace_corpus_source_path(@workspace, @corpus, @knowledge.source_snapshot.source_id, snapshot: 1, page: 1, anchor: "record-#{@knowledge.id}")
    assert_not_includes response.body, "New unrelated title"
    assert_not_includes response.body, "New policy requiring unrelated evidence."
    assert_select "#failure-patterns pre", text: "Request the certificate expiry date."
  end

  test "viewer can inspect escaped reports while foreign same workspace other corpus expired and purged reads fail closed" do
    Membership.create!(workspace: @workspace, user: users(:teammate), role: :viewer)
    sign_in_as users(:teammate)
    get workspace_corpus_evaluation_run_path(@workspace, @corpus, @mixed_run)
    assert_response :success
    assert_select "#failure-patterns input[type=submit]", count: 0
    assert_select "#failure-patterns form", count: 0
    other_corpus = @workspace.corpora.create!(name: "Separate project")
    get workspace_corpus_evaluation_run_path(@workspace, other_corpus, @mixed_run)
    assert_response :not_found
    sign_in_as users(:outsider)
    get workspace_corpus_evaluation_run_path(@workspace, @corpus, @mixed_run)
    assert_response :not_found
    sign_in_as users(:owner)
    @knowledge.source_snapshot.source.update!(expires_at: 1.second.ago)
    get workspace_corpus_evaluation_run_path(@workspace, @corpus, @mixed_run)
    assert_response :not_found
    SourcePurge.call(source: @knowledge.source_snapshot.source, membership: @membership)
    assert_empty EvaluationResult.where(corpus: @corpus)
    assert_empty EvalCaseCheck.where(corpus: @corpus)
    get workspace_corpus_evaluation_run_path(@workspace, @corpus, @mixed_run)
    assert_response :not_found
  end

  test "GET projects only source link metadata and does not put private statements into SQL logs" do
    loaded_attributes = []
    original = CorpusItem.instance_method(:init_with_attributes)
    CorpusItem.define_method(:init_with_attributes) do |attributes, *args|
      loaded_attributes << attributes.keys
      original.bind_call(self, attributes, *args)
    end
    io = StringIO.new
    previous_logger = ActiveRecord::Base.logger
    ActiveRecord::Base.logger = ActiveSupport::Logger.new(io, level: Logger::DEBUG)
    get workspace_corpus_evaluation_run_path(@workspace, @corpus, @mixed_run)
    assert_response :success
    assert_not_empty loaded_attributes
    loaded_attributes.each do |attributes|
      assert_empty attributes & %w[content context title]
    end
    assert_not_includes io.string, "Identify expiry as possible, not confirmed."
    assert_not_includes io.string, "Request the certificate expiry date."
  ensure
    ActiveRecord::Base.logger = previous_logger
    CorpusItem.define_method(:init_with_attributes, original)
  end

  test "untrusted reasons and definitions stay escaped and errors with forged fail decisions supply no patterns" do
    run = request_run
    item = run.evaluation_run_items.find_by!(eval_case: @case)
    decisions = @mixed_run.evaluation_results.find_by!(eval_case: @case).decisions.deep_dup
    decisions.first["reason"] = "<script>private()</script>"
    item.create_evaluation_result!(workspace: @workspace, corpus: @corpus, eval_case: @case, status: "fail", output: support_output, decisions:, created_at: Time.current)
    get workspace_corpus_evaluation_run_path(@workspace, @corpus, run)
    assert_response :success
    assert_select "#failure-patterns script", count: 0
    assert_select "#failure-patterns dd", text: /<script>private\(\)<\/script>/
    error_item = run.evaluation_run_items.find_by!(eval_case: @other_case)
    error_item.create_evaluation_result!(workspace: @workspace, corpus: @corpus, eval_case: @other_case, status: "error", decisions:, created_at: Time.current)
    get workspace_corpus_evaluation_run_path(@workspace, @corpus, run)
    assert_select "[data-failed-check-id]", count: 6
    assert_select "#failure-patterns p", text: /1 execution errors · 0 not executed/
  end
end
