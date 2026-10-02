require "test_helper"
require_relative "../test_helpers/eval_test_helper"

class EvalDefinitionAccessTest < ActionDispatch::IntegrationTest
  include EvalTestHelper
  setup do
    build_eval_definitions
    sign_in_as users(:owner)
  end

  test "contract forms compile fixed cases and membership can be added and removed" do
    get new_workspace_corpus_eval_case_path(@workspace, @corpus, scenario_id: @scenario.id)
    assert_response :success
    assert_select "select[name$='[grader_version_id]']", count: 2
    post workspace_corpus_eval_cases_path(@workspace, @corpus), params: { scenario_id: @scenario.id, version_id: @scenario.current_version_id, checks: @checks.each_with_index.to_h { |check, index| [ index.to_s, check ] } }
    item = EvalCase.order(:id).last
    assert_redirected_to workspace_corpus_eval_case_path(@workspace, @corpus, item)
    follow_redirect!
    assert_select "h2", text: "Target-visible input"
    assert_select ".review-layout > section:nth-child(2) pre" do |nodes|
      input = JSON.parse(nodes.sole.text)
      assert_equal "enterprise", input["known_facts"]["plan"]
      assert_not_includes input.to_json, "private answer"
    end
    post workspace_corpus_eval_suites_path(@workspace, @corpus), params: { eval_suite: { name: "Technical readiness", kind: "evaluation" } }
    suite = EvalSuite.order(:id).last
    assert_redirected_to workspace_corpus_eval_suite_path(@workspace, @corpus, suite)
    patch workspace_corpus_eval_suite_path(@workspace, @corpus, suite), params: { case_id: item.id }
    assert_redirected_to workspace_corpus_eval_suite_path(@workspace, @corpus, suite)
    assert_equal [ item ], suite.reload.eval_cases.to_a
    patch workspace_corpus_eval_suite_path(@workspace, @corpus, suite), params: { remove_case_id: item.id }
    assert_empty suite.reload.eval_cases
  end

  test "malformed mappings return errors and invalid grader edits retain text without new versions" do
    [ {}, { "0" => false }, { "0" => @checks.first } ].each do |checks|
      post workspace_corpus_eval_cases_path(@workspace, @corpus), params: { scenario_id: @scenario.id, version_id: @scenario.current_version_id, checks: }
      assert_response :unprocessable_content
      assert_select "[role=alert]", text: /exactly one grader/
    end
    assert_no_difference "GraderVersion.count" do
      patch workspace_corpus_grader_path(@workspace, @corpus, @action_grader), params: { version_id: @action_grader.current_version_id, grader: { kind: "rubric_judge", rubric: "Keep this edit", confidence_threshold: "2" } }
      assert_response :unprocessable_content
      assert_select "textarea[name='grader[rubric]']", text: "Keep this edit"
    end
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    assert_equal "[FILTERED]", filter.filter("grader" => { "value" => "company rule", "rubric" => "company judgment" }).fetch("grader")
  end

  test "viewers cannot create edit compile or change suites and outsiders cannot read definitions" do
    item = compile_case
    suite = @corpus.eval_suites.create!(workspace: @workspace, name: "Read only")
    Membership.create!(workspace: @workspace, user: users(:teammate), role: :viewer)
    sign_in_as users(:teammate)
    get workspace_corpus_grader_path(@workspace, @corpus, @action_grader)
    assert_response :success
    assert_select "input[type=submit]", count: 0
    post workspace_corpus_graders_path(@workspace, @corpus), params: {}
    assert_response :forbidden
    patch workspace_corpus_grader_path(@workspace, @corpus, @action_grader), params: {}
    assert_response :forbidden
    post workspace_corpus_eval_cases_path(@workspace, @corpus), params: {}
    assert_response :forbidden
    post workspace_corpus_eval_suites_path(@workspace, @corpus), params: {}
    assert_response :forbidden
    patch workspace_corpus_eval_suite_path(@workspace, @corpus, suite), params: { case_id: item.id }
    assert_response :forbidden
    get workspace_corpus_eval_case_path(@workspace, @corpus, item)
    assert_response :success
    get workspace_corpus_eval_case_path(workspaces(:beta_support), @corpus, item)
    assert_response :not_found
    sign_in_as users(:outsider)
    get workspace_corpus_grader_path(@workspace, @corpus, @action_grader)
    assert_response :not_found
  end

  test "expiry hides grader text and case inputs before the hourly purge" do
    item = compile_case
    suite = @corpus.eval_suites.create!(workspace: @workspace, name: "Expiry")
    suite.add_case!(membership: @membership, case_id: item.id)
    @knowledge.source_snapshot.source.update!(expires_at: 1.second.ago)
    get workspace_corpus_grader_path(@workspace, @corpus, @outcome_grader)
    assert_response :not_found
    get workspace_corpus_eval_case_path(@workspace, @corpus, item)
    assert_response :not_found
    get workspace_corpus_eval_suite_path(@workspace, @corpus, suite)
    assert_response :success
    assert_select ".workspace-card", count: 0
    assert_raises(EvalCase::Invalid) { @outcome_grader.revise!(membership: @membership, version_id: @outcome_grader.current_version_id, kind: "rubric_judge", definition: @outcome_grader.current_version.definition) }
  end
end
