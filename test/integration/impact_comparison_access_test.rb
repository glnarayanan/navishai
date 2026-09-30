require "test_helper"
require_relative "../test_helpers/recorded_evaluation_test_helper"

class ImpactComparisonAccessTest < ActionDispatch::IntegrationTest
  include RecordedEvaluationTestHelper
  setup do
    build_compared_evaluation
    sign_in_as users(:owner)
  end

  test "policy refresh exposes exact historical and current dependencies without changing cases or runs" do
    fixed = @case.attributes
    result = @before.evaluation_results.sole.attributes
    prior = @scenario.current_version
    current = @scenario.revise!(membership: @membership, base_version_id: prior.id, attributes: { title: "<script>private assumption</script>" })
    source = @knowledge.source_snapshot.source
    CorpusIntake.call(corpus: @corpus, membership: @membership, name: source.name, kind: "document", bytes: "New policy requires current IdP metadata.")
    get workspace_corpus_source_path(@workspace, @corpus, source)
    assert_response :success
    assert_select "#source-impact" do
      assert_select "a[href='#{workspace_corpus_scenario_path(@workspace, @corpus, @scenario, version: prior.number)}']"
      assert_select "a[href='#{workspace_corpus_scenario_path(@workspace, @corpus, @scenario, version: current.number)}']"
      assert_select "strong", text: "Stale document evidence", count: 2
      assert_select "a[href='#{workspace_corpus_eval_case_path(@workspace, @corpus, @case)}']"
      assert_select "a[href='#{workspace_corpus_eval_suite_path(@workspace, @corpus, @suite)}']"
      assert_select "span", text: "Historical scenario version"
      assert_select "span", text: "Current scenario version"
    end
    assert_select "script", text: /private assumption/, count: 0
    assert_equal fixed, @case.reload.attributes
    assert_equal result, @before.evaluation_results.sole.attributes
    get workspace_corpus_evaluation_run_path(@workspace, @corpus, @after, baseline_id: @before.id)
    assert_response :success
    assert_select "[data-change=recovery]", count: 1
  end

  test "viewer compares saved results without writes and refresh keeps the chosen baseline" do
    Membership.create!(workspace: @workspace, user: users(:teammate), role: :viewer)
    sign_in_as users(:teammate)
    assert_no_difference [ "EvaluationRun.count", "EvaluationResult.count", "AuditEvent.count" ] do
      assert_no_enqueued_jobs do
        get workspace_corpus_evaluation_run_path(@workspace, @corpus, @after, baseline_id: @before.id)
        assert_response :success
        assert_select "form[method=get] select[name=baseline_id]"
        assert_select "#run-comparison [data-change=recovery]", count: 1
        assert_select "a[href='#{workspace_corpus_evaluation_result_path(@workspace, @corpus, @before.evaluation_results.sole)}']", text: "Before result: Fail"
        assert_select "a[href='#{workspace_corpus_evaluation_result_path(@workspace, @corpus, @after.evaluation_results.sole)}']", text: "After result: Pass"
        assert_select "a[href='#{workspace_corpus_evaluation_run_path(@workspace, @corpus, @after, baseline_id: @before.id)}']", text: "Refresh run"
        get workspace_corpus_evaluation_run_path(@workspace, @corpus, @before, baseline_id: @after.id)
        assert_response :success
        assert_select "[data-change=regression]", count: 1
      end
    end
    get workspace_corpus_source_path(@workspace, @corpus, @knowledge.source_snapshot.source)
    assert_response :success
    assert_select "#source-impact a[href='#{workspace_corpus_eval_case_path(@workspace, @corpus, @case)}']"
  end

  test "an older explicitly selected baseline stays visible beyond the bounded picker" do
    100.times do
      @corpus.evaluation_runs.create!(workspace: @workspace, eval_suite: @suite, evaluation_target_version: @target.current_version,
        requested_by: @membership.user, processing_version: EvaluationRun::VERSION, created_at: Time.current)
    end
    get workspace_corpus_evaluation_run_path(@workspace, @corpus, @after)
    assert_response :success
    assert_select "select[name=baseline_id] option[value='#{@before.id}']", count: 0
    get workspace_corpus_evaluation_run_path(@workspace, @corpus, @after, baseline_id: @before.id)
    assert_response :success
    assert_select "select[name=baseline_id] option[selected][value='#{@before.id}']"
    assert_select "[data-change=recovery]", count: 1
  end

  test "self foreign and expired comparisons and dependencies remain private" do
    get workspace_corpus_evaluation_run_path(@workspace, @corpus, @after, baseline_id: @after.id)
    assert_response :see_other
    follow_redirect!
    assert_select "[role=alert]", text: /distinct runs/
    foreign = @workspace.corpora.create!(name: "Another corpus")
    suite = foreign.eval_suites.create!(workspace: @workspace, name: "Private suite")
    target = EvaluationTarget.define!(corpus: foreign, membership: @membership, name: "Private target", configuration: script_configuration)
    foreign_run = foreign.evaluation_runs.create!(workspace: @workspace, eval_suite: suite, evaluation_target_version: target.current_version,
      requested_by: @membership.user, processing_version: EvaluationRun::VERSION, created_at: Time.current)
    get workspace_corpus_evaluation_run_path(@workspace, @corpus, @after, baseline_id: foreign_run.id)
    assert_response :not_found
    sign_in_as users(:outsider)
    get workspace_corpus_evaluation_run_path(@workspace, @corpus, @after, baseline_id: @before.id)
    assert_response :not_found
    get workspace_corpus_source_path(@workspace, @corpus, @knowledge.source_snapshot.source)
    assert_response :not_found
    sign_in_as users(:owner)
    @snapshot.source.update!(expires_at: 1.minute.ago)
    get workspace_corpus_evaluation_run_path(@workspace, @corpus, @after, baseline_id: @before.id)
    assert_response :not_found
    get workspace_corpus_source_path(@workspace, @corpus, @knowledge.source_snapshot.source)
    assert_response :success
    assert_select "#source-impact [role=status]", text: /hidden.*expired/
    assert_select "#source-impact a", count: 0
    assert_not_includes response.body, @scenario.current_version.title
  end

  test "dependency and fixed case pagination keeps independent positions and snapshot selection" do
    50.times do |index|
      @scenario.revise!(membership: @membership, base_version_id: @scenario.current_version_id, attributes: { title: "Dependency revision #{index}" })
      @corpus.eval_cases.create!(workspace: @workspace, scenario_version: @case.scenario_version, scenario_review: @case.scenario_review,
        compiled_by: @membership.user, number: index + 2, compiler_version: @case.compiler_version,
        definition_digest: Digest::SHA256.hexdigest("pagination-#{index}"), contract: @case.contract, created_at: Time.current)
    end
    source = @knowledge.source_snapshot.source
    get workspace_corpus_source_path(@workspace, @corpus, source, snapshot: 1, page: 2)
    assert_response :success
    assert_select "#source-impact .workspace-card", count: 50
    assert_select "#source-impact .source-record", count: 50
    assert_select "nav[aria-label='Dependency pages'] a", text: "Next dependencies" do |links|
      assert_includes links.sole["href"], "dependency_page=2"
      assert_includes links.sole["href"], "snapshot=1"
      assert_includes links.sole["href"], "page=2"
    end
    get workspace_corpus_source_path(@workspace, @corpus, source, snapshot: 1, dependency_page: 2, case_page: 2)
    assert_response :success
    assert_select "#source-impact .workspace-card", count: 1
    assert_select "#source-impact .source-record", count: 1
    assert_select "#source-impact a[href='#{workspace_corpus_eval_case_path(@workspace, @corpus, @case)}']"
  end
end
