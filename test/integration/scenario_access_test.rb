require "test_helper"
require_relative "../test_helpers/scenario_test_helper"

class ScenarioAccessTest < ActionDispatch::IntegrationTest
  include ScenarioTestHelper

  setup do
    build_scenarios
    sign_in_as users(:owner)
  end

  test "read write errors preserve expert input and foreign routes are hidden" do
    get workspace_corpus_scenario_path(@workspace, @corpus, @scenario)
    assert_response :success
    assert_select "h2", text: "Company evidence"
    patch workspace_corpus_scenario_path(@workspace, @corpus, @scenario), params: { version_id: @scenario.current_version_id, scenario: { title: "Keep my edits", known_facts: "broken JSON", hidden_facts: "{}" } }
    assert_response :unprocessable_content
    assert_select "input[name='scenario[title]'][value='Keep my edits']"
    assert_select "textarea[name='scenario[known_facts]']", text: "broken JSON"
    assert_select "[role=alert]", text: /valid JSON/
    get workspace_corpus_scenario_path(workspaces(:beta_support), @corpus, @scenario)
    assert_response :not_found
    get workspace_corpus_scenario_path(@workspace, @corpus, @scenario, version: 99)
    assert_response :not_found
  end

  test "viewer cannot revise review mine or create variants and expiry hides index titles" do
    Membership.create!(workspace: @workspace, user: users(:teammate), role: :viewer)
    sign_in_as users(:teammate)
    get workspace_corpus_scenario_path(@workspace, @corpus, @scenario)
    assert_response :success
    assert_select "input[type=submit]", count: 0
    patch workspace_corpus_scenario_path(@workspace, @corpus, @scenario), params: {}
    assert_response :forbidden
    post review_workspace_corpus_scenario_path(@workspace, @corpus, @scenario), params: {}
    assert_response :forbidden
    post variant_workspace_corpus_scenario_path(@workspace, @corpus, @scenario), params: {}
    assert_response :forbidden
    post workspace_corpus_scenarios_path(@workspace, @corpus), params: { analysis_id: @analysis.id }
    assert_response :forbidden
    travel 366.days do
      sign_in_as users(:teammate)
      get workspace_corpus_scenarios_path(@workspace, @corpus)
      assert_response :success
      assert_select ".workspace-card", count: 0
      get workspace_corpus_scenario_path(@workspace, @corpus, @scenario)
      assert_response :not_found
    end
  end
end
