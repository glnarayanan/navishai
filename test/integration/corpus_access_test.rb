require "test_helper"

class CorpusAccessTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:acme_support)
    @corpus = @workspace.corpora.create!(name: "API history")
    @snapshot = CorpusIntake.call(corpus: @corpus, membership: memberships(:owner_support), name: "KB", kind: "document", bytes: "<script>alert('untrusted')</script>\nRequire diagnostic logs")
    sign_in_as users(:owner)
  end

  test "source HTML is escaped and foreign corpus source and snapshot cannot be read" do
    get workspace_corpus_source_path(@workspace, @corpus, @snapshot.source)
    assert_response :success
    assert_select ".evidence-text", text: /<script>alert/
    assert_select "script", text: /alert\('untrusted'\)/, count: 0
    get workspace_corpus_path(workspaces(:beta_support), @corpus)
    assert_response :not_found
    get workspace_corpus_source_path(@workspace, @corpus, @snapshot.source, snapshot: 2)
    assert_response :not_found
  end

  test "viewer can read but cannot create import or delete" do
    Membership.create!(workspace: @workspace, user: users(:teammate), role: :viewer)
    sign_in_as users(:teammate)
    get workspace_corpus_path(@workspace, @corpus)
    assert_response :success
    assert_select "input[type=file]", count: 0
    assert_no_difference "Corpus.count" do
      post workspace_corpora_path(@workspace), params: { corpus: { name: "No" } }
      assert_response :forbidden
    end
    post workspace_corpus_sources_path(@workspace, @corpus), params: {}
    assert_response :forbidden
    delete workspace_corpus_source_path(@workspace, @corpus, @snapshot.source), params: { confirmation: "KB" }
    assert_response :forbidden
    assert Source.exists?(@snapshot.source_id)
  end

  test "validation errors and explicit source deletion work" do
    post workspace_corpora_path(@workspace), params: { corpus: { name: "" } }
    assert_response :unprocessable_content
    assert_select "[role=alert]"
    delete workspace_corpus_source_path(@workspace, @corpus, @snapshot.source), params: { confirmation: "wrong" }
    assert Source.exists?(@snapshot.source_id)
    delete workspace_corpus_source_path(@workspace, @corpus, @snapshot.source), params: { confirmation: "KB" }
    assert_response :see_other
    assert_not Source.exists?(@snapshot.source_id)
    assert_not CorpusItem.exists?(source_snapshot_id: @snapshot.id)
  end
end
