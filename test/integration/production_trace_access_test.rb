require "test_helper"

class ProductionTraceAccessTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:acme_support)
    @membership = memberships(:owner_support)
    @corpus = @workspace.corpora.create!(name: "Trace review")
    data = JSON.parse(File.read(Rails.root.join("test/fixtures/files/production_traces.json")))
    data.sole["human_correction"] = "<script>alert('trace')</script>"
    bytes = data.to_json
    @snapshot = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Recorded failures", kind: "traces", bytes:)
    @item = @snapshot.corpus_items.sole
    sign_in_as users(:owner)
  end

  test "expert can propose once and untrusted trace text stays escaped" do
    post workspace_corpus_scenarios_path(@workspace, @corpus), params: { trace_item_id: @item.id }
    assert_response :see_other
    assert_redirected_to workspace_corpus_scenario_path(@workspace, @corpus, @corpus.scenarios.sole)
    get workspace_corpus_source_path(@workspace, @corpus, @snapshot.source)
    assert_select "h4", text: "Reported correction"
    assert_select "a", text: "Open trace scenario"
    assert_select "p", text: /not expert labels/
    assert_select "p", text: "<script>alert('trace')</script>"
    assert_select "script", text: /alert\('trace'\)/, count: 0
    assert_no_difference "Scenario.count" do
      post workspace_corpus_scenarios_path(@workspace, @corpus), params: { trace_item_id: @item.id }
    end
    get workspace_corpus_source_path(workspaces(:beta_support), @corpus, @snapshot.source)
    assert_response :not_found
    foreign = workspaces(:beta_support).corpora.create!(name: "Foreign traces")
    post workspace_corpus_scenarios_path(@workspace, foreign), params: { trace_item_id: @item.id }
    assert_response :not_found
  end

  test "viewers and expired evidence cannot propose or inspect traces" do
    Membership.create!(workspace: @workspace, user: users(:teammate), role: :viewer)
    sign_in_as users(:teammate)
    get workspace_corpus_source_path(@workspace, @corpus, @snapshot.source)
    assert_response :success
    assert_select "button", text: "Propose scenario from trace", count: 0
    post workspace_corpus_scenarios_path(@workspace, @corpus), params: { trace_item_id: @item.id }
    assert_response :forbidden
    travel 366.days do
      sign_in_as users(:owner)
      get workspace_corpus_source_path(@workspace, @corpus, @snapshot.source)
      assert_response :not_found
      assert_no_difference "Scenario.count" do
        post workspace_corpus_scenarios_path(@workspace, @corpus), params: { trace_item_id: @item.id }
      end
      follow_redirect!
      assert_select "[role=alert]", text: /unexpired production trace/
    end
  end
end
