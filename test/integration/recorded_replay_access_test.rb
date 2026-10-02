require "test_helper"
require_relative "../test_helpers/recorded_evaluation_test_helper"

class RecordedReplayAccessTest < ActionDispatch::IntegrationTest
  include RecordedEvaluationTestHelper
  setup do
    build_recorded_evaluation
    sign_in_as users(:owner)
  end

  test "matching cases and trace provenance stay visible and failed target input is retained" do
    get workspace_corpus_source_path(@workspace, @corpus, @snapshot.source)
    assert_response :success
    assert_select "summary", text: "Cases with identical visible input (1)"
    assert_select "a[href=?]", workspace_corpus_eval_case_path(@workspace, @corpus, @case)
    post workspace_corpus_evaluation_targets_path(@workspace, @corpus), params: { adapter: "recorded", name: "Keep my trace target", trace_item_id: @knowledge.id }
    assert_response :unprocessable_content
    assert_select "input[name=name][value='Keep my trace target']"
    assert_select "select[name=adapter] option[selected][value=recorded]"
    assert_select "input[name=trace_item_id][value=?]", @knowledge.id
    assert_select "[role=alert]", text: /unexpired production trace/
    get workspace_corpus_evaluation_target_path(@workspace, @corpus, @target)
    assert_select "a[href=?]", workspace_corpus_source_path(@workspace, @corpus, @snapshot.source, snapshot: 1, page: 1, anchor: "record-#{@trace_item.id}")
    assert_select "p", text: /not a new agent execution/
  end

  test "exact matches beyond the first hundred cases stay discoverable without writes or jobs" do
    cases = compile_replay_history(situations: 100.times.map { |index| "Unrelated fixture situation #{index}" } + [ @trace["input"]["situation"] ])
    late = cases.last
    assert_equal 102, @corpus.eval_cases.count
    assert_no_difference [ "AuditEvent.count", "EvaluationRun.count", "ScenarioVersion.count", "HumanLabel.count" ] do
      assert_no_enqueued_jobs do
        get workspace_corpus_source_path(@workspace, @corpus, @snapshot.source)
        assert_response :success
        assert_select "summary", text: /Cases with identical visible input/ do |summaries|
          assert_equal "Cases with identical visible input (2)", summaries.sole.text.strip
        end
        assert_select "#replay-cases-#{@trace_item.id} summary", text: "Cases with identical visible input (2)"
        [ @case, late ].each do |eval_case|
          assert_select "#replay-cases-#{@trace_item.id} a[href=?]", workspace_corpus_eval_case_path(@workspace, @corpus, eval_case)
        end
      end
    end
  end

  test "matching case pages retain trace snapshot and independent page positions and recover when empty" do
    matches = compile_replay_history(situations: [ @trace["input"]["situation"] ] * 50)
    path = workspace_corpus_source_path(@workspace, @corpus, @snapshot.source)
    get path, params: { matching_item_id: @trace_item.id, matching_page: 1, dependency_page: 2, case_page: 2, decision_page: 3, snapshot: 1, host: "foreign.invalid", protocol: "javascript" }
    assert_response :success
    assert_select "#replay-cases-#{@trace_item.id} ul li", count: 50
    assert_select "#replay-cases-#{@trace_item.id} summary", text: "Cases with identical visible input (51)"
    assert_select "#replay-cases-#{@trace_item.id} a", text: "Next matching cases" do |links|
      uri = URI.parse(links.sole["href"])
      assert_nil uri.scheme
      assert_nil uri.host
      assert_equal path, uri.path
      assert_equal "replay-cases-#{@trace_item.id}", uri.fragment
      query = Rack::Utils.parse_query(uri.query)
      assert_equal %w[2 2 2 3 1], query.values_at("matching_page", "dependency_page", "case_page", "decision_page", "snapshot")
      get links.sole["href"]
    end
    assert_response :success
    assert_select "#replay-cases-#{@trace_item.id}[open] ul li", count: 1
    assert_select "#replay-cases-#{@trace_item.id} a[href=?]", workspace_corpus_eval_case_path(@workspace, @corpus, matches.last)
    assert_select "#replay-cases-#{@trace_item.id} a", text: "Previous matching cases"
    get path, params: { matching_item_id: @trace_item.id, matching_page: 9999, snapshot: 1 }
    assert_select "#replay-cases-#{@trace_item.id} p", text: /No matching cases on this page/
    assert_select "#replay-cases-#{@trace_item.id} a", text: "First matching page"
    @knowledge.source_snapshot.source.update!(expires_at: 1.minute.ago)
    get path
    assert_response :success
    assert_select "#replay-cases-#{@trace_item.id} p", text: /hidden because a corpus source has expired/
    assert_select "#replay-cases-#{@trace_item.id} ul li", count: 0
  end

  test "viewer cannot define or queue replay and foreign trace input stays hidden" do
    Membership.create!(workspace: @workspace, user: users(:teammate), role: :viewer)
    sign_in_as users(:teammate)
    post workspace_corpus_evaluation_targets_path(@workspace, @corpus), params: { adapter: "recorded", trace_item_id: @trace_item.id }
    assert_response :forbidden
    post workspace_corpus_evaluation_runs_path(@workspace, @corpus), params: { suite_id: @suite.id, target_version_id: @target.current_version_id }
    assert_response :forbidden
    get workspace_corpus_evaluation_target_path(workspaces(:beta_support), @corpus, @target)
    assert_response :not_found
  end
end
