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

  test "oversized historical evidence refuses all rows while exact next page and current search stay usable" do
    attributes = { workspace_id: @workspace.id, corpus_id: @corpus.id, source_snapshot_id: @snapshot.id,
      title: "Historical large fixture", content: "historical-private-content " + "x" * 99_000,
      context: { diagnostic: "雪" * 40_000 }, created_at: Time.current }
    CorpusItem.insert_all!(49.times.map { |index| attributes.merge(external_id: "large-#{index}") })
    CorpusItem.insert_all!(2.times.map { |index| attributes.merge(external_id: "recovery-#{index}", title: "Later small record", content: "Complete historical recovery", context: { complete: true }) })
    current = CorpusIntake.call(corpus: @corpus, membership: memberships(:owner_support), name: "KB", kind: "document", bytes: "Current replacement policy")
    loaded = []
    observer = ->(event) { loaded << event.payload[:record_count] if event.payload[:class_name] == "CorpusItem" }
    ActiveSupport::Notifications.subscribed(observer, "instantiation.active_record") do
      get workspace_corpus_source_path(@workspace, @corpus, @snapshot.source), params: { snapshot: 1, dependency_page: 3, case_page: 2 }
    end
    assert_response :success
    assert_empty loaded
    assert_select "#source-evidence [role=status]", text: /52 snapshot records.*page 1/
    assert_select "#source-evidence [role=alert]", text: /10 MiB.*next page.*no page records were loaded.*does not include historical snapshots/
    assert_select "#source-evidence > article", count: 0
    assert_not_includes response.body, "historical-private-content"
    assert_not_includes response.body, "Require diagnostic logs"
    recovery = css_select("#source-evidence > p > a").sole["href"]
    next_link = css_select("nav[aria-label='Record pages'] a").sole["href"]
    query = Rack::Utils.parse_query(URI(next_link).query)
    assert_equal "1", query["snapshot"]
    assert_equal "3", query["dependency_page"]
    assert_equal "2", query["case_page"]
    ActiveSupport::Notifications.subscribed(observer, "instantiation.active_record") { get next_link }
    assert_response :success
    assert_equal [ 2 ], loaded
    assert_select "#source-evidence > article", count: 2
    assert_select "#source-evidence .evidence-text", text: /Complete historical recovery/, count: 2
    assert_select "#source-evidence [role=alert]", count: 0
    assert_select "nav[aria-label='Record pages'] a", text: "Next records", count: 0
    get recovery
    assert_response :success
    assert_select "#corpus-records > details", count: 1
    assert_select "#corpus-records pre", text: "Current replacement policy"
    get workspace_corpus_source_path(@workspace, @corpus, current.source)
    assert_response :success
    assert_select "#source-evidence > article", count: 1
    assert_select "#source-evidence [role=alert]", count: 0
  end

  test "JSONL multipart intake streams a file above the original bound and keeps errors private" do
    Tempfile.create([ "navishai-http-fixture-", ".jsonl" ]) do |file|
      12.times { |index| file.puts(JSON.generate({ id: "large-#{index}", title: "Large context", content: "Fixture body", context: { evidence: "雪" * 300_000 } })) }
      file.flush
      assert_operator file.size, :>, CorpusIntake::MAX_BYTES
      assert_difference "CorpusItem.count", 12 do
        post workspace_corpus_sources_path(@workspace, @corpus), params: { name: "Large JSONL fixture", kind: "conversation_lines",
          file: Rack::Test::UploadedFile.new(file.path, "application/x-ndjson"), redaction: "email", retention_days: 30 }
        assert_response :see_other
      end
      assert_equal "[FILTERED]", request.filtered_parameters["file"]
      snapshot = @corpus.sources.find_by!(name: "Large JSONL fixture").current_snapshot
      assert_equal "support-conversation-jsonl-v1", snapshot.processing_version
      assert_equal Digest::SHA256.file(file.path).hexdigest, snapshot.digest
      assert_equal "雪" * 300_000, snapshot.corpus_items.find_by!(external_id: "large-11").context.fetch("evidence")
    end
    assert_no_difference [ "Source.count", "SourceSnapshot.count", "CorpusItem.count", "AuditEvent.count" ] do
      post workspace_corpus_sources_path(@workspace, @corpus), params: { name: "Invalid JSONL", kind: "conversation_lines",
        file: fixture_file_upload("support_export.json", "application/json"), redaction: "exact", redaction_values: "private-fixture-rule", retention_days: 30 }
      assert_response :see_other
      assert_not_includes flash.to_hash.to_json, "private-fixture-rule"
      follow_redirect!
      assert_select "[role=alert]", text: /one conversation object/
      assert_select "select[name=kind] option[value=conversation_lines][selected]"
      assert_select "select[name=kind][aria-describedby=intake-format-help]"
      assert_select "select[name=redaction] option[value=exact][selected]"
      assert_select "textarea[name=redaction_values]", text: ""
    end
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
