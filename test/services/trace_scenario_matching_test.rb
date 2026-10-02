require "test_helper"
require_relative "../support/failure_matching_fixture"

class TraceScenarioMatchingTest < ActiveSupport::TestCase
  include FailureMatchingFixture
  include ActiveSupport::Testing::ConstantStubbing
  setup { build_failure_matching_fixture }

  test "real version ceiling refuses before candidate definitions and source associations load" do
    1999.times { matching_version }
    complete = TraceScenarioMatching.call(item: @item)
    assert_equal 2000, complete.searched_versions
    assert_equal 5, complete.candidates.size
    assert_equal @version.id, complete.candidates.first.version.id
    assert_nil complete.message
    matching_version
    SupportTrace.payload(@item)
    loaded = []
    observer = ->(event) do
      if %w[ScenarioVersion Scenario ScenarioReview ScenarioEvidence CorpusItem SourceSnapshot Source].include?(event.payload[:class_name])
        loaded << [ event.payload[:class_name], event.payload[:record_count] ]
      end
    end
    refused = nil
    assert_no_difference [ "TraceScenarioDecision.count", "ScenarioReview.count", "AuditEvent.count" ] do
      ActiveSupport::Notifications.subscribed(observer, "instantiation.active_record") do
        refused = TraceScenarioMatching.call(item: @item)
      end
    end
    # Validating the requested trace still refreshes its own source metadata.
    assert_equal [ [ "Source", 1 ] ], loaded
    assert_empty refused.candidates
    assert_equal 0, refused.searched_versions
    assert_equal 0, refused.searched_bytes
    assert_match(/2000 current versions; no text searched/, refused.message)
  end

  test "matching loads link fields and known facts but not unused source or contract payloads" do
    source_item = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Private context fixture", kind: "conversations",
      bytes: [ { id: "private", title: "Retained origin", content: @document.content,
        context: { private_data: "unused-private-context " * 20_000 } } ].to_json).corpus_items.sole
    previous = matching_version(item: source_item)
    version = previous.scenario.revise!(membership: @membership, base_version_id: previous.id,
      attributes: { hidden_facts: { "private" => "not a matching input" }, requirements: ScenarioVersion::REQUIREMENT_TYPES.index_with { [ "unused contract " + "x" * 1900 ] } })
    version.scenario_evidence.create!(workspace: @corpus.workspace, corpus: @corpus,
      corpus_item: @document, kind: "knowledge", excerpt: "Invoices require a billing contact.")
    result = TraceScenarioMatching.call(item: @item)
    candidate = result.candidates.find { |entry| entry.version.id == version.id }
    assert_not_nil candidate
    assert_equal 2, candidate.version.number
    assert_equal({ "idp" => "Okta" }, candidate.equal_facts)
    assert_equal({ "trace" => "enterprise", "scenario" => "business" }, candidate.conflicting_facts["plan"])
    assert_equal({ "situation" => "After certificate rotation, authentication fails. Request expiry evidence.",
      "known_facts" => { "plan" => "business", "idp" => "Okta" },
      "knowledge" => [ { "reference" => "corpus-item-#{@document.id}", "content" => "Invoices require a billing contact." } ] }, candidate.version.target_input)
    assert_not candidate.version.has_attribute?(:hidden_facts)
    assert_not candidate.version.has_attribute?(:requirements)
    assert_not candidate.version.has_attribute?(:selection_reason)
    [ candidate.version.scenario.corpus_item, candidate.evidence.sole.corpus_item ].each do |item|
      assert_equal source_item.id, item.id
      assert_equal "private", item.external_id
      assert_equal "Retained origin", item.title
      assert_equal @corpus.workspace_id, item.workspace_id
      assert_equal @corpus.id, item.corpus_id
      assert_equal source_item.source_snapshot_id, item.source_snapshot_id
      assert_not item.has_attribute?(:content)
      assert_not item.has_attribute?(:context)
    end
    assert_equal "unused-private-context " * 20_000, source_item.reload.context.fetch("private_data")
    assert_equal "not a matching input", version.reload.hidden_facts.fetch("private")
    CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Certificate policy", kind: "document", bytes: "Replacement policy")
    assert_not TraceScenarioMatching.eligible?(candidate.version)
    assert_no_difference "TraceScenarioDecision.count" do
      assert_raises(Scenario::Invalid) { append_decision(version: candidate.version) }
    end
  end

  test "real UTF8 byte overflow refuses before searched strings and excerpts load" do
    title = "雪" * 500
    situation = "certificate " + "x" * 9000
    900.times { matching_version(title:, situation:) }
    first_bytes = [ "Certificate rotation diagnostics", "After certificate rotation, authentication fails. Request expiry evidence.",
      "Certificate rotation diagnostics", "For certificate rotation failures, request expiry evidence before changing configuration." ].join("\n").bytesize
    row_bytes = [ title, situation, title, "For certificate rotation failures, request expiry evidence before changing configuration." ].join("\n").bytesize
    overflow_rows = (10.megabytes - first_bytes) / row_bytes + 1
    assert_operator overflow_rows, :<, 900
    queries = []
    observer = ->(event) { queries << event.payload[:sql] }
    result = nil
    ActiveSupport::Notifications.subscribed(observer, "sql.active_record") { result = TraceScenarioMatching.call(item: @item) }
    assert_empty result.candidates
    assert_equal 0, result.searched_versions
    assert_equal first_bytes + overflow_rows * row_bytes, result.searched_bytes
    assert_match(/no text searched or truncated/, result.message)
    assert_empty queries.grep(/SELECT "scenario_versions"\.\*|"scenario_versions"\."situation"|SELECT "scenario_evidence"\.\*|SELECT "corpus_items"\.\*/)
  end

  test "exact joined UTF8 byte ceiling includes separators but not known facts" do
    title = "Café certificate rotation 雪 \"configuration\""
    situation = "Certificate rotation\nneeds expiry evidence and configuration diagnostics."
    matching_version(title:, situation:, facts: { "reported" => false, "unknown" => nil, "idp" => "Okta" })
    excerpt = "For certificate rotation failures, request expiry evidence before changing configuration."
    expected = [ "Certificate rotation diagnostics", "After certificate rotation, authentication fails. Request expiry evidence.",
      "Certificate rotation diagnostics", excerpt ].join("\n").bytesize + [ title, situation, title, excerpt ].join("\n").bytesize
    stub_const(TraceScenarioMatching, :MAX_BYTES, expected) do
      result = TraceScenarioMatching.call(item: @item)
      assert_nil result.message
      assert_equal 2, result.searched_versions
      assert_equal expected, result.searched_bytes
      assert_equal 2, result.candidates.size
    end
    stub_const(TraceScenarioMatching, :MAX_BYTES, expected - 1) do
      result = TraceScenarioMatching.call(item: @item)
      assert_empty result.candidates
      assert_equal 0, result.searched_versions
      assert_equal expected, result.searched_bytes
    end
  end

  test "multiple asymmetric traces load the candidate corpus once and retain distinct results" do
    trace = SupportTrace.payload(@item).deep_dup
    trace.merge!("id" => "invoice-trace", "title" => "Invoice failure", "observed_failure" => "Invoice billing contact was omitted.")
    trace["input"]["situation"] = "The invoice billing contact is missing."
    trace["input"]["known_facts"] = {}
    other = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Billing traces", kind: "traces", bytes: [ trace ].to_json).corpus_items.sole
    invoice = matching_version(title: "Invoice billing contact", situation: "The billing contact needs an invoice.", facts: {}, excerpt: "Invoices require a billing contact.")
    queries = []
    observer = ->(_name, _start, _finish, _id, payload) { queries << payload.fetch(:sql) if payload.fetch(:sql).include?('FROM "scenario_versions"') }
    results = ActiveSupport::Notifications.subscribed(observer, "sql.active_record") { TraceScenarioMatching.call_all(items: [ @item, other ]) }
    assert_equal 3, queries.size
    assert_equal 1, queries.count { |sql| sql.include?("COUNT(*)") }
    assert_equal @version, results.fetch(@item.id).candidates.sole.version
    assert_equal invoice, results.fetch(other.id).candidates.sole.version
    assert_equal 2, results.fetch(@item.id).searched_versions
    assert_equal results.fetch(@item.id).searched_bytes, results.fetch(other.id).searched_bytes
  end

  test "different visible input suggests source terms but never replay and plan conflicts remain" do
    unrelated = matching_version(title: "Enterprise Okta invoice", situation: "Enterprise Okta billing contact needs invoice.",
      facts: { "plan" => "enterprise", "idp" => "Okta" }, excerpt: "Invoices require a billing contact.")
    result = TraceScenarioMatching.call(item: @item)
    candidate = result.candidates.sole
    assert_equal @version, candidate.version
    assert_not_equal unrelated, candidate.version
    assert_includes candidate.shared_terms, "certificate"
    assert_equal({ "idp" => "Okta" }, candidate.equal_facts)
    assert_equal({ "trace" => "enterprise", "scenario" => "business" }, candidate.conflicting_facts["plan"])
    assert_raises(RecordedTarget::Error) { RecordedTarget.call(trace_item: @item, input: @version.target_input) }
    assert_equal @document, candidate.evidence.sole.corpus_item
  end

  test "false null zero missing and numeric types do not collapse" do
    equal, conflicts, missing = TraceScenarioMatching.compare_facts({ "a" => false, "b" => nil, "c" => 0, "d" => nil, "e" => 0 }, { "a" => nil, "b" => false, "c" => false, "e" => 0.0 })
    assert_empty equal
    assert_equal %w[a b c e], conflicts.keys
    assert_equal "scenario", missing["d"]["missing_from"]
  end

  test "beyond first hundred versions searched top five stable and bound refuses instead of samples" do
    101.times { matching_version(title: "Invoice billing", situation: "Billing contact.", excerpt: "Invoices require a billing contact.") }
    later = matching_version(title: "SSO certificate rotation", situation: "SSO stopped after changed certificate configuration.")
    result = TraceScenarioMatching.call(item: @item)
    assert_includes result.candidates.map(&:version), later
    assert_equal 103, result.searched_versions
    stub_const(TraceScenarioMatching, :MAX_VERSIONS, 100) do
      refused = TraceScenarioMatching.call(item: @item)
      assert_empty refused.candidates
      assert_match(/no text searched/, refused.message)
    end
  end

  test "byte overflow refuses complete corpus and trace corrections are never searched" do
    stub_const(TraceScenarioMatching, :MAX_BYTES, 1) do
      result = TraceScenarioMatching.call(item: @item)
      assert_empty result.candidates
      assert_match(/no text searched or truncated/, result.message)
    end
    trace_version = SupportTrace.propose!(item: @item, membership: @membership).current_version
    result = TraceScenarioMatching.call(item: @item)
    assert_empty result.candidates.find { |candidate| candidate.version == trace_version }.evidence
    trace_version.scenario.revise!(membership: @membership, base_version_id: trace_version.id,
      attributes: { title: "Billing invoice", situation: "Invoice billing contact.", taxonomy_label: "Billing" })
    assert_not_includes TraceScenarioMatching.call(item: @item).candidates.map { |candidate| candidate.version.scenario_id }, trace_version.scenario_id
    @document.source_snapshot.source.update!(expires_at: 1.minute.ago)
    assert_empty TraceScenarioMatching.call(item: @item).candidates
  end

  test "top five ordering is deterministic and foreign corpus versions are absent" do
    versions = 6.times.map { matching_version }
    first = TraceScenarioMatching.call(item: @item).candidates.map { |candidate| candidate.version.id }
    assert_equal 5, first.size
    assert_equal ([ @version ] + versions).first(5).map(&:id), first
    assert_equal first, TraceScenarioMatching.call(item: @item).candidates.map { |candidate| candidate.version.id }
    foreign = @corpus.workspace.corpora.create!(name: "Foreign corpus")
    document = CorpusIntake.call(corpus: foreign, membership: @membership, name: "Foreign policy", kind: "document", bytes: @document.content).corpus_items.sole
    foreign_version = matching_version(corpus: foreign, item: document)
    assert_not_includes TraceScenarioMatching.call(item: @item).candidates.map { |candidate| candidate.version.id }, foreign_version.id
  end
end
