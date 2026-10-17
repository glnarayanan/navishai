require "test_helper"

class WorkspaceOverviewTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:acme_support)
    sign_in_as users(:owner)
  end

  test "an empty workspace explains the first step instead of claiming features are missing" do
    get workspace_path(@workspace)
    assert_select "h2", "Start with a corpus"
    assert_select "a", text: "Create a corpus"
    assert_select "ol.steps li", count: 4
    assert_not_includes response.body, "not yet available"
  end

  test "a workspace with corpora lists counts per corpus" do
    corpus = @workspace.corpora.create!(name: "Overview corpus")
    get workspace_path(@workspace)
    assert_select "table.data-table tbody tr", count: 1 do
      assert_select "td a[href='#{workspace_corpus_path(@workspace, corpus)}']", text: "Overview corpus"
      assert_select "td.numeric", text: "0", count: 3
      assert_select "td", text: "No runs yet"
    end
  end
end
