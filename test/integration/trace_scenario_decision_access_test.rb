require "test_helper"
require_relative "../support/failure_matching_fixture"

class TraceScenarioDecisionAccessTest < ActionDispatch::IntegrationTest
  include FailureMatchingFixture
  setup do
    build_failure_matching_fixture
    sign_in_as users(:owner)
  end

  test "GET is read only POST retains errors and history and lifetime hides associations" do
    assert_no_difference [ "TraceScenarioDecision.count", "ScenarioVersion.count", "AuditEvent.count" ] do
      assert_no_enqueued_jobs do
        get source_path
        assert_response :success
        assert_select "p", text: /Exact shared terms:.*certificate/
        assert_select "h6", text: "Conflicting known facts — review caution"
      end
    end
    assert_no_difference "TraceScenarioDecision.count" do
      post decision_path, params: values.merge(decision: "invalid", reason: "Retain this explanation")
      assert_response :unprocessable_entity
      assert_select "textarea", text: "Retain this explanation"
    end
    post decision_path, params: values
    assert_response :see_other
    follow_redirect!
    assert_select "p", text: /Latest for this expert and version/
    assert_not @version.approved?
    @document.source_snapshot.source.update!(expires_at: 1.minute.ago)
    get source_path
    assert_response :success
    assert_select "p", text: /Matches hidden/
    assert_select "p", text: /Latest for this expert/, count: 0
    assert_no_difference "TraceScenarioDecision.count" do
      post decision_path, params: values
      assert_response :unprocessable_entity
    end
  end

  test "second history page never presents an old label as an expert's latest decision" do
    51.times { |index| append_decision(reason: "Association history #{index}") }
    get source_path, params: { snapshot: @item.source_snapshot.number, page: 1, decision_page: 2 }
    assert_response :success
    assert_select "p", text: "Association history 0"
    assert_select "p", text: "Association history 50", count: 0
    assert_select "p", text: /Earlier decision/, count: 1
    assert_select "p", text: /Latest for this expert and version/, count: 0
    assert_select "a[href*='decision_page=1'][href*='snapshot=1']", text: "Previous decisions"
  end

  test "viewers foreign corpora and stale forms cannot save" do
    foreign = @corpus.workspace.corpora.create!(name: "Foreign")
    assert_no_difference "TraceScenarioDecision.count" do
      post decide_trace_workspace_corpus_source_path(@corpus.workspace, foreign, @item.source_snapshot.source), params: values
      assert_response :not_found
      post decide_trace_workspace_corpus_source_path(workspaces(:beta_support), @corpus, @item.source_snapshot.source), params: values
      assert_response :not_found
      @version.scenario.revise!(membership: @membership, base_version_id: @version.id, attributes: { title: "Updated certificate" })
      post decision_path, params: values
      assert_response :unprocessable_entity
      assert_select "summary", text: "Retained decision on unavailable version"
    end
    Membership.create!(workspace: @corpus.workspace, user: users(:teammate), role: :viewer)
    sign_in_as users(:teammate)
    get source_path
    assert_response :success
    assert_select "input[type=submit][value='Append trace decision']", count: 0
    assert_no_difference "TraceScenarioDecision.count" do
      post decision_path, params: values
      assert_response :forbidden
    end
  end

  private
    def source_path
      workspace_corpus_source_path(@corpus.workspace, @corpus, @item.source_snapshot.source)
    end

    def decision_path
      decide_trace_workspace_corpus_source_path(@corpus.workspace, @corpus, @item.source_snapshot.source)
    end

    def values
      { corpus_item_id: @item.id, scenario_version_id: @version.id, decision: "match", reason: "Certificate evidence overlaps, entitlement differs." }
    end
end
