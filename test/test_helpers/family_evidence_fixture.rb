module FamilyEvidenceFixture
  def build_family_evidence_fixture
    @membership = memberships(:owner_support)
    @workspace = @membership.workspace
    @corpus = @workspace.corpora.create!(name: "Family evidence fixture")
    records = 55.times.map do |index|
      { id: "family-#{index + 1}", title: "Diagnostic #{index + 1}", content: "Collect logs and metadata.", context: {} }
    end
    [ true, false, "true", nil, 1 ].each_with_index do |value, index|
      records[index][:context] = { escalated: value, reopened: value, failed: value }
    end
    records[0][:content] = "Engineering reopened an outage; collect logs."
    records[0][:context][:impact] = "critical"
    records[1][:context][:impact] = "Critical"
    records[2][:context][:impact] = "security"
    records[6][:context] = { escalated: "false", reopened: "false", failed: "false" }
    records[7][:context] = { escalated: 0, reopened: 0, failed: 0, diagnostic: "outage engineering unresolved" }
    records[7][:title] = "Outage engineering unresolved"
    records[50][:context] = { escalated: true, reopened: false, failed: true, plan: "enterprise" }
    records[50][:content] = "<script>untrusted()</script> Collect logs. " + "x" * 4100 + " data loss"
    @snapshot = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Family history", kind: "conversations", bytes: records.to_json)
    @items = @snapshot.corpus_items.order(:id).to_a
    @analysis, @cluster = build_fixed_family(CorpusAnalysis::METHOD)
  end

  def build_fixed_family(method)
    analysis = @corpus.corpus_analyses.create!(workspace: @workspace, requested_by: @membership.user,
      processing_method: method, state: "complete", scenario_limit: 1, configuration: {},
      summary: { "selected" => 0, "conversations" => 55, "represented_clusters" => 0, "clusters" => 1 })
    @items.each { |item| analysis.corpus_analysis_inputs.create!(workspace: @workspace, corpus: @corpus, corpus_item: item) }
    cluster = analysis.issue_clusters.create!(workspace: @workspace, corpus: @corpus, proposed_label: "Diagnostics",
      signals: { "count" => 55, "proposal_reason" => "Proposed high importance", "evidence" => @items.map { |item| { "reference" => "corpus-item-#{item.id}", "quote" => "Collect logs" } } })
    @items.each do |item|
      cluster.cluster_members.create!(workspace: @workspace, corpus: @corpus, corpus_item: item, signals: [ "critical importance proposal" ])
    end
    [ analysis, cluster ]
  end

  def refresh_family_export
    CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Family history", kind: "conversations",
      bytes: [ { id: "later", title: "New export", content: "No original records remain in current export.", context: { failed: true } } ].to_json)
  end

  def assert_source_rows_loaded(count)
    loaded = []
    observer = ->(event) { loaded << event.payload[:record_count] if event.payload[:class_name] == "CorpusItem" }
    ActiveSupport::Notifications.subscribed(observer, "instantiation.active_record") { yield }
    assert_equal count, loaded.sum, "Load complete source rows only for this page or selected evidence."
  end
end
