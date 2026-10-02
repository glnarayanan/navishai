require "test_helper"
require_relative "../test_helpers/evaluation_test_helper"

class EvaluationAccessTest < ActionDispatch::IntegrationTest
  include EvaluationTestHelper
  setup do
    build_evaluation
    @run = request_run
    EvaluationRunJob.perform_now(@run.id)
    @result = @run.evaluation_results.sole
    @regression = @corpus.eval_suites.create!(workspace: @workspace, name: "SSO regressions", kind: "regression")
    sign_in_as users(:owner)
  end

  test "target forms retain invalid JSON and run result retains empty regression errors" do
    post workspace_corpus_evaluation_targets_path(@workspace, @corpus), params: { name: "New target", configuration: "{unfinished" }
    assert_response :unprocessable_content
    assert_select "textarea[name=configuration]", text: "{unfinished"
    assert_select "input[name=name][value='New target']"
    original_version_id = @target.current_version_id
    patch workspace_corpus_evaluation_target_path(@workspace, @corpus, @target), params: { version_id: @target.current_version_id, configuration: script_configuration(output: support_output(text: "<script>steal()</script>")).to_json }
    assert_response :see_other
    follow_redirect!
    assert_select "script", text: /steal/, count: 0
    assert_select "pre", text: /<script>steal\(\)<\/script>/
    assert_no_difference "EvaluationTargetVersion.count" do
      patch workspace_corpus_evaluation_target_path(@workspace, @corpus, @target), params: { version_id: original_version_id, configuration: script_configuration.to_json }
      assert_response :unprocessable_content
      assert_select "input[name=version_id][value='#{original_version_id}']"
      assert_select "[role=alert]", text: /target changed/
    end
    post regression_workspace_corpus_evaluation_result_path(@workspace, @corpus, @result), params: { suite_id: @regression.id, rationale: "" }
    assert_response :unprocessable_content
    assert_select "[role=alert]", text: /Rationale can't be blank/
    post regression_workspace_corpus_evaluation_result_path(@workspace, @corpus, @result), params: { suite_id: @regression.id, rationale: "Never skip certificate evidence." }
    assert_redirected_to workspace_corpus_eval_suite_path(@workspace, @corpus, @regression)
    follow_redirect!
    assert_select ".source-record", text: /Never skip certificate evidence/
    post workspace_corpus_evaluation_runs_path(@workspace, @corpus), params: { suite_id: @regression.id, target_version_id: @target.current_version_id }
    assert_redirected_to workspace_corpus_evaluation_run_path(@workspace, @corpus, EvaluationRun.order(:id).last)
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    assert_equal "[FILTERED]", filter.filter("configuration" => "private fixtures").fetch("configuration")
  end

  test "viewer reads escaped results but cannot create targets runs or regressions and member cannot manage targets" do
    access = Membership.create!(workspace: @workspace, user: users(:teammate), role: :viewer)
    sign_in_as users(:teammate)
    get workspace_corpus_evaluation_result_path(@workspace, @corpus, @result)
    assert_response :success
    assert_select "input[type=submit]", count: 0
    get workspace_corpus_evaluation_target_path(@workspace, @corpus, @target)
    assert_response :success
    assert_select "input[type=submit]", count: 0
    post workspace_corpus_evaluation_targets_path(@workspace, @corpus), params: {}
    assert_response :forbidden
    patch workspace_corpus_evaluation_target_path(@workspace, @corpus, @target), params: {}
    assert_response :forbidden
    post workspace_corpus_evaluation_runs_path(@workspace, @corpus), params: {}
    assert_response :forbidden
    patch workspace_corpus_evaluation_run_path(@workspace, @corpus, @run), params: {}
    assert_response :forbidden
    post regression_workspace_corpus_evaluation_result_path(@workspace, @corpus, @result), params: {}
    assert_response :forbidden
    access.update!(role: :member)
    post workspace_corpus_evaluation_targets_path(@workspace, @corpus), params: {}
    assert_response :forbidden
    post workspace_corpus_evaluation_runs_path(@workspace, @corpus), params: { suite_id: @suite.id, target_version_id: @target.current_version_id }
    assert_response :see_other
  end

  test "foreign and expired target run and result reads stay hidden including suite history" do
    @result.add_regression!(membership: @membership, suite_id: @regression.id, rationale: "Private regression rationale")
    sign_in_as users(:outsider)
    [ workspace_corpus_evaluation_target_path(@workspace, @corpus, @target), workspace_corpus_evaluation_run_path(@workspace, @corpus, @run),
      workspace_corpus_evaluation_result_path(@workspace, @corpus, @result) ].each do |path|
      get path
      assert_response :not_found
    end
    sign_in_as users(:owner)
    @knowledge.source_snapshot.source.update!(expires_at: 1.second.ago)
    [ workspace_corpus_evaluation_targets_path(@workspace, @corpus), workspace_corpus_evaluation_target_path(@workspace, @corpus, @target),
      workspace_corpus_evaluation_runs_path(@workspace, @corpus), workspace_corpus_evaluation_run_path(@workspace, @corpus, @run),
      workspace_corpus_evaluation_result_path(@workspace, @corpus, @result) ].each do |path|
      get path
      assert_response :not_found
    end
    get workspace_corpus_eval_suite_path(@workspace, @corpus, @regression)
    assert_response :success
    assert_select ".workspace-card", count: 0
    assert_select ".source-record", count: 0
    assert_select "input[type=submit]", count: 0
    assert_not_includes response.body, "Private regression rationale"
  end
end
