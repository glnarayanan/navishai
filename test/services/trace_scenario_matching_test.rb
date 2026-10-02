require "test_helper"
require_relative "../support/failure_matching_fixture"

class TraceScenarioMatchingTest < ActiveSupport::TestCase
  include FailureMatchingFixture
  include ActiveSupport::Testing::ConstantStubbing
  setup { build_failure_matching_fixture }

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
    assert_equal 1, queries.size
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
