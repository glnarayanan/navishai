require "test_helper"

class CorpusExplorationTest < ActionDispatch::IntegrationTest
  setup do
    @membership = memberships(:owner_support)
    @workspace = @membership.workspace
    @corpus = @workspace.corpora.create!(name: "Exploration fixture")
    @snapshot = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Technical export", kind: "conversations", bytes: [
      { id: "auth-12", title: "Certificate rotation", content: "ACS 500 after rotation. Literal boundary: %_\\. admin@example.org", context: { plan: "enterprise", diagnostic: "clé" } },
      { id: "api-43", title: "Webhook retry", content: "Inspect the request IDs for duplicate events.", context: { plan: "starter" } }
    ].to_json)
    @document = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Current policy", kind: "document", bytes: "Certificate policy: collect metadata first.")
    sign_in_as users(:owner)
  end

  test "literal search covers each retained field and source filtering intersects rather than widens results" do
    { "cErTiFiCaTe" => 2, "AUTH-12" => 1, "ACS 500" => 1, "ENTERPRISE" => 1, "CLÉ" => 1, "admin@example.org" => 0 }.each do |query, count|
      get workspace_corpus_path(@workspace, @corpus), params: { corpus_query: query }
      assert_response :success
      assert_select "#corpus-records > details", count: count
      assert_select "#corpus-records [role=status]", text: /#{count} matching record/
    end
    get workspace_corpus_path(@workspace, @corpus), params: { corpus_query: "certificate", source_id: @snapshot.source_id }
    assert_response :success
    assert_select "#corpus-records > details > summary", text: "auth-12 · Certificate rotation", count: 1
    get workspace_corpus_path(@workspace, @corpus), params: { corpus_query: "ACS 500", source_id: @document.source_id }
    assert_response :success
    assert_select "#corpus-records > details", count: 0
  end

  test "wildcards quotes SQL-like phrases and HTML stay data" do
    [ "%", "_", "\\", "%_\\" ].each do |query|
      get workspace_corpus_path(@workspace, @corpus), params: { corpus_query: query }
      assert_response :success
      assert_select "#corpus-records > details > summary", text: "auth-12 · Certificate rotation", count: 1
    end
    [ "' OR 1=1 --", "<script>foreign()</script>" ].each do |query|
      get workspace_corpus_path(@workspace, @corpus), params: { corpus_query: query }
      assert_response :success
      assert_select "#corpus-records > details", count: 0
      assert_select "input[name=corpus_query]" do |inputs|
        assert_equal query, inputs.sole["value"]
      end
      assert_select "script", text: /foreign\(\)/, count: 0
    end
  end

  test "only current unexpired same-corpus sources can supply results or provenance" do
    old_record = @snapshot.corpus_items.find_by!(external_id: "auth-12")
    current = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Technical export", kind: "conversations",
      bytes: [ { id: "new-auth", title: "Current SSO issue", content: "Certificate expiry needs metadata." } ].to_json)
    @document.source.update!(expires_at: 1.minute.ago)
    get workspace_corpus_path(@workspace, @corpus), params: { corpus_query: "certificate" }
    assert_response :success
    assert_select "#corpus-records > details > summary", text: "new-auth · Current SSO issue", count: 1
    assert_select "#corpus-records a[href='#{workspace_corpus_source_path(@workspace, @corpus, current.source, snapshot: 2, page: 1, anchor: "record-#{current.corpus_items.sole.id}")}']"
    get workspace_corpus_source_path(@workspace, @corpus, @snapshot.source, snapshot: 1)
    assert_response :success
    assert_select "article#record-#{old_record.id}"
    get workspace_corpus_path(@workspace, @corpus), params: { source_id: @document.source_id }
    assert_response :not_found
    foreign = @workspace.corpora.create!(name: "Separate corpus")
    private_snapshot = CorpusIntake.call(corpus: foreign, membership: @membership, name: "Foreign policy", kind: "document", bytes: "Certificate private company facts.")
    get workspace_corpus_path(@workspace, @corpus), params: { source_id: private_snapshot.source_id, corpus_query: "certificate" }
    assert_response :not_found
    get workspace_corpus_source_path(@workspace, @corpus, private_snapshot.source, snapshot: 1)
    assert_response :not_found
    sign_in_as users(:outsider)
    get workspace_corpus_path(@workspace, @corpus), params: { corpus_query: "certificate" }
    assert_response :not_found
  end

  test "viewer search is read only and its phrase is filtered from parameters and request paths" do
    Membership.create!(workspace: @workspace, user: users(:teammate), role: :viewer)
    sign_in_as users(:teammate)
    assert_no_difference [ "CorpusItem.count", "SourceSnapshot.count", "AuditEvent.count", "CorpusAnalysis.count" ] do
      assert_no_enqueued_jobs do
        get workspace_corpus_path(@workspace, @corpus), params: { corpus_query: "enterprise", source_id: @snapshot.source_id }
        assert_response :success
        assert_select "form[method=get] input[name=corpus_query]"
        assert_select "#corpus-records > details", count: 1
        assert_not_includes request.filtered_path, "enterprise"
        assert_includes request.filtered_path, "corpus_query=[FILTERED]"
        assert_equal "no-referrer", response.headers["Referrer-Policy"]
      end
    end
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    assert_equal "[FILTERED]", filter.filter("corpus_query" => "private search")["corpus_query"]
  end

  test "phrase bounds preserve errors and whitespace resets the search" do
    get workspace_corpus_path(@workspace, @corpus), params: { corpus_query: "x" * 200 }
    assert_response :success
    [ "x" * 201, "bad\0query" ].each do |query|
      get workspace_corpus_path(@workspace, @corpus), params: { corpus_query: query }
      assert_response :unprocessable_content
      assert_select "#corpus-records [role=alert]", text: /200 characters and no null bytes/
      assert_select "#corpus-records > details", count: 0
    end
    get workspace_corpus_path(@workspace, @corpus), params: { corpus_query: "  " }
    assert_response :success
    assert_select "#corpus-records > details", count: 3
  end

  test "filtered pagination retains search and provenance reaches records beyond the first source page" do
    snapshot = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Large export", kind: "conversations",
      bytes: 51.times.map { |index| { id: "paging-#{index}", title: "Certificate pagination #{index}", content: "Collect certificate evidence." } }.to_json)
    path = workspace_corpus_path(@workspace, @corpus)
    get path, params: { corpus_query: "certificate", source_id: snapshot.source_id, protocol: "javascript", host: "alert(1)//" }
    assert_response :success
    assert_select "#corpus-records > details", count: 50
    assert_select "#corpus-records [role=status]", text: /51 matching records/
    assert_select "nav[aria-label='Record pages'] a", text: "Next records" do |links|
      assert_includes links.sole["href"], "corpus_query=certificate"
      assert_includes links.sole["href"], "source_id=#{snapshot.source_id}"
      assert_includes links.sole["href"], "#corpus-records"
      assert URI(links.sole["href"]).relative?, links.sole["href"]
      assert_equal path, URI(links.sole["href"]).path
    end
    get css_select("nav[aria-label='Record pages'] a").sole["href"]
    assert_response :success
    assert_select "#corpus-records > details > summary", text: "paging-50 · Certificate pagination 50", count: 1
    assert_select "nav[aria-label='Record pages'] a", text: "Previous records" do |links|
      assert URI(links.sole["href"]).relative?, links.sole["href"]
      assert_equal path, URI(links.sole["href"]).path
      query = Rack::Utils.parse_query(URI(links.sole["href"]).query)
      assert_equal "certificate", query["corpus_query"]
      assert_equal snapshot.source_id.to_s, query["source_id"]
      assert_equal "1", query["page"]
    end
    item = snapshot.corpus_items.order(:id).last
    assert_select "#corpus-records a[href='#{workspace_corpus_source_path(@workspace, @corpus, snapshot.source, snapshot: 1, page: 2, anchor: "record-#{item.id}")}']"
    get workspace_corpus_source_path(@workspace, @corpus, snapshot.source, snapshot: 1, page: 2)
    assert_response :success
    assert_select "article#record-#{item.id}", text: /Certificate pagination 50/
    assert_select "nav[aria-label='Record pages'] a", text: "Previous records" do |links|
      assert_not_includes links.sole["href"], "record_id"
      query = Rack::Utils.parse_query(URI(links.sole["href"]).query)
      assert_equal "1", query["page"]
      assert_equal "1", query["snapshot"]
    end
    get css_select("nav[aria-label='Record pages'] a").sole["href"]
    assert_response :success
    assert_select "#source-evidence > article", count: 50
  end
end
