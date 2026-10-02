require "test_helper"
require_relative "../test_helpers/source_export_fixture"

class SourceExportTest < ActionDispatch::IntegrationTest
  include SourceExportFixture

  setup do
    @membership = memberships(:owner_support)
    @workspace = @membership.workspace
    @corpus = @workspace.corpora.create!(name: "Export fixture")
    @old = export_snapshot(corpus: @corpus, membership: @membership)
    @current = export_snapshot(corpus: @corpus, membership: @membership, marker: "current", count: 2)
    @source = @old.source
    sign_in_as users(:owner)
  end

  test "complete exact historical and current JSON with safe headers and content-free audit" do
    [ [ @old, 61, "historical" ], [ @current, 2, "current" ] ].each do |snapshot, count, marker|
      assert_difference -> { AuditEvent.where(action: "source.downloaded").count }, 1 do
        download(snapshot)
      end
      assert_response :success
      data = JSON.parse(response.body)
      assert_equal "navishai-retained-source-v1", data.fetch("format")
      assert_equal @source.id, data.dig("source", "id")
      assert_equal snapshot.id, data.dig("snapshot", "id")
      assert_equal snapshot.number, data.dig("snapshot", "number")
      assert_equal snapshot.digest, data.dig("snapshot", "digest")
      assert_equal snapshot.redaction, data.dig("snapshot", "redaction")
      assert_equal snapshot.processing_version, data.dig("snapshot", "processing_version")
      assert_equal snapshot.created_at.iso8601(6), data.dig("snapshot", "intake_time")
      assert_equal count, data.fetch("records").size
      data.fetch("records").each_with_index do |record, index|
        assert_equal "#{marker}-#{index}", record.fetch("external_id")
        assert_equal "#{marker} café #{index}", record.fetch("title")
        assert_equal "#{marker} \"quoted\"\n\\ path 雪 [email redacted]", record.fetch("text")
        assert_equal({ "nested" => [ { "[email redacted]" => "[email redacted]", "facts" => [ false, nil, 0, "雪" ] } ] }, record.fetch("context"))
      end
      assert_equal "no-store", response.headers["Cache-Control"]
      assert_equal "nosniff", response.headers["X-Content-Type-Options"]
      assert_includes response.headers["Content-Disposition"], "source-#{@source.id}-snapshot-#{snapshot.id}.json"
      assert_match(/\Aapplication\/json/, response.media_type)
      audit = AuditEvent.where(action: "source.downloaded").last
      assert_equal({}, audit.metadata)
      assert_equal "SourceSnapshot", audit.subject_type
      assert_equal snapshot.id, audit.subject_id
      assert_equal @membership.user, audit.actor
    end
  end

  test "confirmation error preserves input and historical snapshot without audit" do
    assert_no_difference -> { AuditEvent.count } do
      download(@old, confirmation: "wrong 雪")
    end
    assert_response :unprocessable_content
    assert_select "#source-download[open]"
    assert_select "input[name=download_confirmation][value='wrong 雪']"
    assert_select "input[name=snapshot_id][value='#{@old.id}']"
    assert_select "summary", text: "Download retained snapshot 1"
    assert_nil response.headers["Content-Disposition"]
  end

  test "exact text exports immutable rule provenance without retaining or returning the values" do
    snapshot = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Exact source", kind: "document",
      bytes: "Fixture Private Customer needs logs.", redaction: "exact", redaction_values: "Fixture Private Customer")
    @source = snapshot.source
    download(snapshot)
    assert_response :success
    data = JSON.parse(response.body)
    assert_equal "exact", data.dig("snapshot", "redaction")
    assert_equal 1, data.dig("snapshot", "mask_count")
    assert_equal Digest::SHA256.hexdigest('["Fixture Private Customer"]'), data.dig("snapshot", "mask_digest")
    assert_equal "[text redacted] needs logs.", data.fetch("records").sole.fetch("text")
    assert_not_includes response.body, "Fixture Private Customer"
    get workspace_corpus_source_path(@workspace, @corpus, @source)
    assert_response :success
    assert_select ".page-heading", text: /Exact text masked/
    assert_select "[role=status]", text: /not approval to disclose data/
    assert_select "dd", text: /1 unique value;/
    assert_not_includes response.body, "Fixture Private Customer"
  end

  test "nested production trace retains masked input and reported output" do
    trace = JSON.parse(File.read(Rails.root.join("test/fixtures/files/production_traces.json")))
    trace.first.fetch("input")["known_facts"]["nested"] = { "contacts" => [ "person@example.org", "雪" ] }
    snapshot = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Trace export", kind: "traces", bytes: JSON.generate(trace))
    @source = snapshot.source
    download(snapshot)
    assert_response :success
    record = JSON.parse(response.body).fetch("records").first
    assert_equal [ "[email redacted]", "雪" ], record.dig("context", "support_trace", "input", "known_facts", "nested", "contacts")
    assert_equal "I changed the SSO configuration for [email redacted]. Try again.", record.dig("context", "support_trace", "output", "messages", 0, "content")
    assert_includes record.fetch("text"), "[email redacted]"
    assert_not_includes response.body, "admin@example.org"
  end

  test "GET is read-only and member and viewer cannot download or see controls" do
    writes = []
    observer = ->(event) { writes << event.payload[:sql] if event.payload[:sql].match?(/\A\s*(INSERT|UPDATE|DELETE)\b/i) }
    assert_no_difference -> { AuditEvent.count } do
      ActiveSupport::Notifications.subscribed(observer, "sql.active_record") do
        assert_no_enqueued_jobs { get workspace_corpus_source_path(@workspace, @corpus, @source, snapshot: 1) }
      end
    end
    assert_empty writes
    assert_response :success
    %w[member viewer].each do |role|
      member = @workspace.memberships.create!(user: users(:teammate), role:)
      sign_in_as users(:teammate)
      get workspace_corpus_source_path(@workspace, @corpus, @source)
      assert_response :success
      assert_select "#source-download", count: 0
      assert_no_difference -> { AuditEvent.count } do
        download(@old)
      end
      assert_response :forbidden
      member.destroy!
    end
  end

  test "manager and admin reuse managing-data permission and native CSRF rejects missing token" do
    %w[manager admin].each do |role|
      member = @workspace.memberships.create!(user: users(:teammate), role:)
      sign_in_as users(:teammate)
      download(@old)
      assert_response :success
      member.destroy!
    end
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    assert_no_difference -> { AuditEvent.count } do
      download(@old)
    end
    assert_response :unprocessable_content
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end

  test "foreign workspace corpus source and snapshot fail closed" do
    other_corpus = @workspace.corpora.create!(name: "Other corpus")
    other = export_snapshot(corpus: other_corpus, membership: @membership)
    sibling = export_snapshot(corpus: @corpus, membership: @membership, name: "Other source")
    assert_no_difference -> { AuditEvent.count } do
      [ other, sibling ].each do |snapshot|
        download(snapshot)
        assert_response :not_found
      end
      post download_snapshot_workspace_corpus_source_path(@workspace, other_corpus, @source), params: { snapshot_id: @old.id, download_confirmation: @source.name }
      assert_response :not_found
      post download_snapshot_workspace_corpus_source_path(workspaces(:beta_support), @corpus, @source), params: { snapshot_id: @old.id, download_confirmation: @source.name }
      assert_response :not_found
      download(nil)
      assert_response :not_found
    end
  end

  test "expiry deletion and revoked membership block stale requests" do
    @source.update!(expires_at: 1.second.ago)
    assert_no_difference -> { AuditEvent.count } do
      download(@old)
      assert_response :not_found
    end
    @source.update!(expires_at: 1.day.from_now)
    member = @workspace.memberships.create!(user: users(:teammate), role: :manager)
    member.update!(role: :viewer)
    assert_raises(Current::RoleAccessDenied) { @source.download_snapshot!(snapshot_id: @old.id, membership: member, confirmation: @source.name) }
    member.destroy!
    assert_raises(ActiveRecord::RecordNotFound) { @source.download_snapshot!(snapshot_id: @old.id, membership: member, confirmation: @source.name) }
    SourcePurge.call(source: @source, membership: @membership)
    assert_no_difference -> { AuditEvent.count } do
      download(@old)
      assert_response :not_found
    end
  end

  test "exact complete byte boundary permits and one byte less refuses without audit" do
    json = @source.download_snapshot!(snapshot_id: @old.id, membership: @membership, confirmation: @source.name)
    original = Source::EXPORT_MAX_BYTES
    Source.send(:remove_const, :EXPORT_MAX_BYTES)
    Source.const_set(:EXPORT_MAX_BYTES, json.bytesize)
    download(@old)
    assert_response :success
    assert_equal json, response.body
    Source.send(:remove_const, :EXPORT_MAX_BYTES)
    Source.const_set(:EXPORT_MAX_BYTES, json.bytesize - 1)
    assert_no_difference -> { AuditEvent.count } do
      download(@old)
    end
    assert_response :unprocessable_content
    assert_nil response.headers["Content-Disposition"]
    assert_select "[role=alert]", text: /no partial file/
  ensure
    Source.send(:remove_const, :EXPORT_MAX_BYTES)
    Source.const_set(:EXPORT_MAX_BYTES, original)
  end

  test "download preflight does not mistake JSON spacing or expanded numbers for exported bytes" do
    context = { "typed" => 200.times.map { { "number" => 1.25e-100, "flag" => false, "missing" => nil } },
      "雪 \"key\"" => [ "many spaces   stay", "quoted \" and \\ escaped\n\t", "雪 café" ] }
    snapshot = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Numeric context fixture", kind: "conversations",
      bytes: [ { id: "numeric", title: "Numeric record", content: "Exact context", context: } ].to_json)
    @source = snapshot.source
    json = @source.download_snapshot!(snapshot_id: snapshot.id, membership: @membership, confirmation: @source.name)
    database_bytes = snapshot.corpus_items.sum(Arel.sql("octet_length(context::text)"))
    assert_operator database_bytes, :>, json.bytesize
    original = Source::EXPORT_MAX_BYTES
    Source.send(:remove_const, :EXPORT_MAX_BYTES)
    Source.const_set(:EXPORT_MAX_BYTES, json.bytesize)
    download(snapshot)
    assert_response :success
    assert_equal context, JSON.parse(response.body).fetch("records").sole.fetch("context")
    assert_equal json, response.body
  ensure
    if original
      Source.send(:remove_const, :EXPORT_MAX_BYTES)
      Source.const_set(:EXPORT_MAX_BYTES, original)
    end
  end

  test "record ceiling refuses complete snapshot rather than paginating" do
    original = Source::EXPORT_MAX_RECORDS
    Source.send(:remove_const, :EXPORT_MAX_RECORDS)
    Source.const_set(:EXPORT_MAX_RECORDS, 60)
    assert_no_difference -> { AuditEvent.count } do
      download(@old)
    end
    assert_response :unprocessable_content
    assert_nil response.headers["Content-Disposition"]
  ensure
    Source.send(:remove_const, :EXPORT_MAX_RECORDS)
    Source.const_set(:EXPORT_MAX_RECORDS, original)
  end

  test "mask expansion refuses oversized retained context before materializing a download" do
    snapshot = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Expanded context fixture", kind: "conversations",
      bytes: [ { id: "expanded", title: "Small record", content: "Small retained text", context: { details: "aaa" * 1.megabyte } } ].to_json,
      redaction: "exact", redaction_values: "aaa")
    source = snapshot.source
    loaded = []
    observer = ->(event) { loaded << event.payload[:record_count] if event.payload[:class_name] == "CorpusItem" }
    assert_no_difference "AuditEvent.count" do
      ActiveSupport::Notifications.subscribed(observer, "instantiation.active_record") do
        error = assert_raises(CorpusIntake::Invalid) { source.download_snapshot!(snapshot_id: snapshot.id, membership: @membership, confirmation: source.name) }
        assert_includes error.message, "10 MiB"
        assert_includes error.message, "no partial file"
      end
    end
    assert_empty loaded
    assert_equal 1, snapshot.corpus_items.count
    assert_equal "[text redacted]" * 1.megabyte, snapshot.corpus_items.sole.context.fetch("details")
  end

  test "production byte and record ceilings refuse real oversized retained records" do
    extra = { workspace_id: @workspace.id, corpus_id: @corpus.id, source_snapshot_id: @old.id,
      title: "Bound fixture", content: "x" * 100_000, context: {}, created_at: Time.current }
    CorpusItem.insert_all!(106.times.map { |index| extra.merge(external_id: "large-#{index}") })
    assert_no_difference -> { AuditEvent.count } do
      download(@old)
    end
    assert_response :unprocessable_content
    assert_select "[role=alert]", text: /10 MiB/
    extra[:content] = "Small record"
    CorpusItem.insert_all!(1834.times.map { |index| extra.merge(external_id: "many-#{index}") })
    assert_equal 2001, @old.corpus_items.count
    assert_no_difference -> { AuditEvent.count } do
      download(@old)
    end
    assert_response :unprocessable_content
    assert_select "[role=alert]", text: /2000 records/
    assert_nil response.headers["Content-Disposition"]
  end

  private
    def download(snapshot, confirmation: @source.name)
      post download_snapshot_workspace_corpus_source_path(@workspace, @corpus, @source), params: { snapshot_id: snapshot&.id, download_confirmation: confirmation }
    end
end
