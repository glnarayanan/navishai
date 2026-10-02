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
