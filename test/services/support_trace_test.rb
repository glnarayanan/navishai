require "test_helper"

class SupportTraceTest < ActiveSupport::TestCase
  setup do
    @membership = memberships(:owner_support)
    @corpus = @membership.workspace.corpora.create!(name: "Production failures")
    @traces = JSON.parse(File.read(Rails.root.join("test/fixtures/files/production_traces.json")))
  end

  test "intake keeps fixed reported input output correction and provenance with recursive masking" do
    @traces.sole["input"]["known_facts"]["contact"] = "security@example.org"
    snapshot = import
    item = snapshot.corpus_items.sole
    assert_equal "support-trace-v1", snapshot.processing_version
    assert_equal Digest::SHA256.hexdigest(@traces.to_json), snapshot.digest
    assert_equal @membership.user, snapshot.imported_by
    assert_equal "[email redacted]", SupportTrace.payload(item)["input"]["known_facts"]["contact"]
    assert_equal "I changed the SSO configuration for [email redacted]. Try again.", SupportTrace.payload(item)["output"]["messages"].sole["content"]
    assert_includes item.content, "Reported correction (not an expert label)"
    assert_equal snapshot.id, import.id
    @traces.sole["target_version"] = "sso-agent-2026-09-29"
    changed = import
    assert_equal 2, changed.number
    assert_equal "sso-agent-2026-09-28", SupportTrace.payload(item.reload)["target_version"]
    assert_raises(ActiveRecord::ReadOnlyRecord) { item.update!(context: {}) }
    assert_raises(ActiveRecord::StatementInvalid) do
      CorpusItem.transaction(requires_new: true) { CorpusItem.where(id: item.id).update_all(context: {}) }
    end
  end

  test "malformed partial hidden oversized and duplicate trace batches leave no records" do
    invalid = [ @traces.sole.merge("schema" => "support-trace-v2"), @traces.sole.except("observed_at"),
      @traces.sole.merge("observed_at" => "2026-19-28T15:45:00Z"), @traces.sole.merge("observed_at" => "2026-09-28T15:45:00"),
      @traces.sole.merge("input" => @traces.sole["input"].merge("hidden_facts" => { "answer" => "expired" })),
      @traces.sole.merge("input" => @traces.sole["input"].merge("knowledge" => [ { "reference" => "kb", "content" => nil } ])),
      @traces.sole.merge("output" => @traces.sole["output"].except("escalation")),
      @traces.sole.merge("human_correction" => "bad\0text"), @traces.sole.merge("id" => ""),
      @traces.sole.merge("target_version" => "x" * (SupportTrace::MAX_BYTES + 1)) ]
    batches = invalid.map { |trace| [ @traces.sole, trace ].to_json } + [ "null", "[]", "{}", "not JSON", [ @traces.sole, @traces.sole ].to_json ]
    batches.each do |bytes|
      assert_no_difference [ "Source.count", "SourceSnapshot.count", "CorpusItem.count", "AuditEvent.count" ] do
        assert_raises(CorpusIntake::Invalid) { import(bytes:) }
      end
    end
  end

  test "byte boundary and post masking bounds reject oversized retained traces atomically" do
    trace = @traces.sole.deep_dup
    trace["output"]["messages"].sole["content"] = ""
    trace["output"]["messages"].sole["content"] = "x" * (SupportTrace::MAX_BYTES - trace.to_json.bytesize)
    assert_equal SupportTrace::MAX_BYTES, trace.to_json.bytesize
    assert_equal trace, SupportTrace.validate!(trace)
    trace["output"]["messages"].sole["content"] += "é"
    assert_raises(CorpusIntake::Invalid) { SupportTrace.validate!(trace) }
    @traces.sole["input"]["known_facts"]["contact"] = "a@b.co " * 1200
    SupportTrace.validate!(@traces.sole)
    assert_no_difference [ "Source.count", "SourceSnapshot.count", "CorpusItem.count" ] do
      assert_raises(CorpusIntake::Invalid) { import }
    end
  end

  test "proposals reuse exact source identity and cannot turn imported corrections into approval" do
    item = import.corpus_items.sole
    scenario = SupportTrace.propose!(item:, membership: @membership)
    version = scenario.current_version
    assert_equal "SSO stopped after a customer changed the certificate.", version.situation
    assert_equal({ "plan" => "enterprise", "idp" => "Okta" }, version.known_facts)
    assert_equal({}, version.hidden_facts)
    assert_equal ScenarioVersion::REQUIREMENT_TYPES.index_with { [] }, version.requirements
    assert_equal item, version.scenario_evidence.sole.corpus_item
    assert_equal item.content.first(4000), version.scenario_evidence.sole.excerpt
    assert_not version.approved?
    assert_no_difference [ "Scenario.count", "ScenarioVersion.count", "AuditEvent.count" ] do
      assert_equal scenario.id, SupportTrace.propose!(item:, membership: @membership).id
    end
    assert_raises(Scenario::Invalid) { scenario.review!(membership: @membership, version_id: version.id, decision: "approve") }
    assert_raises(Current::RoleAccessDenied) { SupportTrace.propose!(item:, membership: memberships(:outsider_beta)) }
    viewer = Membership.create!(workspace: @corpus.workspace, user: users(:teammate), role: :viewer)
    assert_raises(Current::RoleAccessDenied) { SupportTrace.propose!(item:, membership: viewer) }
    travel 366.days do
      assert_raises(CorpusIntake::Invalid) { SupportTrace.propose!(item:, membership: @membership) }
    end
  end

  test "recorded knowledge is not automatically granted and empty failure reports cannot seed candidates" do
    @traces.sole["input"]["knowledge"] = [ { "reference" => "old-kb", "content" => "Legacy promise: every configuration can be reset." } ]
    scenario = SupportTrace.propose!(item: import.corpus_items.sole, membership: @membership)
    assert_empty scenario.current_version.target_input["knowledge"]
    @traces.sole["observed_failure"] = ""
    item = import.corpus_items.sole
    assert_raises(Scenario::Invalid) { SupportTrace.propose!(item:, membership: @membership) }
  end

  test "discovery excludes trace reports while purge clears even scenarios without analysis parents" do
    snapshot = import
    assert_raises(CorpusIntake::Invalid) { CorpusAnalysis.request!(corpus: @corpus, membership: @membership, scenario_limit: 3) }
    document = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Current policy", kind: "document", bytes: "Request the expiry date.")
    analysis = CorpusAnalysis.request!(corpus: @corpus, membership: @membership, scenario_limit: 3)
    assert_equal document.corpus_items.pluck(:id), analysis.corpus_items.pluck(:id)
    scenario = SupportTrace.propose!(item: snapshot.corpus_items.sole, membership: @membership)
    assert_nil scenario.cluster_member_id
    SourcePurge.call(source: document.source, membership: @membership)
    assert_not Scenario.exists?(scenario.id)
    assert_not ScenarioVersion.exists?(scenario.current_version_id)
    assert_empty ScenarioEvidence.where(corpus: @corpus)
    assert_equal 1, @corpus.corpus_items.count
    assert Source.exists?(snapshot.source_id)
    snapshot.source.update!(expires_at: 1.minute.ago)
    SourceRetentionJob.perform_now
    assert_not CorpusItem.exists?(source_snapshot_id: snapshot.id)
  end

  private
    def import(bytes: @traces.to_json)
      CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Production trace fixture", kind: "traces", bytes:)
    end
end
