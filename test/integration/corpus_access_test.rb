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

  test "upload applies exact choices and repairs errors without storing or echoing private values" do
    path = workspace_corpus_sources_path(@workspace, @corpus)
    upload = fixture_file_upload("support_export.json", "application/json")
    assert_difference [ "Source.count", "SourceSnapshot.count" ], 1 do
      post path, params: { name: "Exact fixture", kind: "conversations", file: upload, retention_days: 30,
        redaction: "exact", redaction_values: "admin@example.org" }
      assert_response :see_other
    end
    snapshot = @corpus.sources.find_by!(name: "Exact fixture").current_snapshot
    assert_equal "exact", snapshot.redaction
    assert_equal 1, snapshot.mask_count
    assert_not_includes snapshot.corpus_items.pluck(:content).join, "admin@example.org"
    assert_equal "[FILTERED]", request.filtered_parameters["redaction_values"]
    assert_not_includes flash.to_hash.to_json, "admin@example.org"
    assert_no_difference [ "Source.count", "SourceSnapshot.count", "CorpusItem.count", "AuditEvent.count" ] do
      post path, params: { name: "Exact fixture", kind: "conversations", file: fixture_file_upload("support_export.json", "application/json"),
        retention_days: 2, redaction: "exact", redaction_values: "private-invalid-value\0" }
      assert_response :see_other
      assert_not_includes flash.to_hash.to_json, "private-invalid-value"
      follow_redirect!
      assert_select "[role=alert]", text: /without null bytes/
      assert_select "select[name=redaction] option[value=exact][selected]"
      assert_select "textarea[name=redaction_values]", text: ""
      assert_not_includes response.body, "private-invalid-value"
    end
    assert_equal snapshot.id, snapshot.source.reload.current_snapshot_id
    Membership.create!(workspace: @workspace, user: users(:teammate), role: :viewer)
    sign_in_as users(:teammate)
    get workspace_corpus_path(@workspace, @corpus)
    assert_select "textarea[name=redaction_values]", count: 0
    assert_no_difference [ "Source.count", "SourceSnapshot.count", "CorpusItem.count", "AuditEvent.count" ] do
      post path, params: { redaction: "exact", redaction_values: "private-invalid-value" }
      assert_response :forbidden
    end
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
