require "test_helper"
require_relative "../test_helpers/scenario_test_helper"
require_relative "../test_helpers/family_evidence_fixture"

class ScenarioTest < ActiveSupport::TestCase
  include ScenarioTestHelper
  include FamilyEvidenceFixture

  setup { build_scenarios }

  test "mining keeps selection and source evidence but never approves historical answers" do
    version = @scenario.current_version
    assert_equal "mined", version.origin
    assert_empty version.requirements["outcomes"]
    assert_includes version.requirements["actions"], "Request the expiry date before changing configuration."
    assert_equal @scenario.cluster_member.selection_reason, version.selection_reason
    assert_equal @scenario.corpus_item, version.scenario_evidence.sole.corpus_item
    assert_equal "critical", @scenarios.find { |scenario| scenario.corpus_item.external_id == "api" }.current_version.importance
    assert_not version.approved?
    assert_raises(Scenario::Invalid) { @scenario.review!(membership: @membership, version_id: version.id, decision: "approve") }
    assert_no_difference "Scenario.count" do
      assert_equal @scenarios.map(&:id).sort, ScenarioMining.call(analysis: @analysis, membership: @membership).map(&:id).sort
    end
  end

  test "expert nomination creates one unapproved source-backed draft without rewriting fixed selection" do
    build_family_evidence_fixture
    refresh_family_export
    member = @cluster.cluster_members.find_by!(corpus_item: @items[50])
    definition = @analysis.attributes
    reason = "Reported failure beyond the first page merits expert review."
    scenario = nil
    assert_difference([ "Scenario.count", "ScenarioVersion.count", "ScenarioEvidence.count", "AuditEvent.count" ], 1) do
      assert_source_rows_loaded(1) do
        scenario = ScenarioMining.call(analysis: @analysis, membership: @membership, member_id: member.id, reason:).sole
      end
    end
    version = scenario.current_version
    assert_equal member.id, scenario.cluster_member_id
    assert_equal @items[50], scenario.corpus_item
    assert_equal @items[50], version.scenario_evidence.sole.corpus_item
    assert_equal @membership.user, version.created_by
    assert_equal "Expert nominated this fixed record for review: #{reason}", version.selection_reason
    assert_empty version.requirements["outcomes"]
    assert_empty version.scenario_reviews
    assert_not version.approved?
    assert_raises(Scenario::Invalid) { scenario.review!(membership: @membership, version_id: version.id, decision: "approve") }
    assert_equal definition, @analysis.reload.attributes
    assert_nil member.reload.selection_reason
    assert_empty ClusterMember.selected.where(issue_cluster: @analysis.issue_clusters)
    assert_empty ScenarioMining.call(analysis: @analysis, membership: @membership)
    assert_equal 0, HumanLabel.where(corpus: @corpus).count
    saved = version.attributes
    assert_no_difference [ "Scenario.count", "ScenarioVersion.count", "ScenarioEvidence.count", "AuditEvent.count" ] do
      assert_equal scenario.id, ScenarioMining.call(analysis: @analysis, membership: @membership, member_id: member.id, reason: "A second nomination must not revise history.").sole.id
    end
    assert_equal saved, version.reload.attributes
  end

  test "a maximum length nomination cannot revise an existing approved scenario or its review" do
    approve_scenario
    version = @scenario.current_version
    definition = version.attributes
    review = version.latest_review.attributes
    assert_no_difference [ "Scenario.count", "ScenarioVersion.count", "ScenarioReview.count", "ScenarioEvidence.count", "HumanLabel.count", "AuditEvent.count" ] do
      result = ScenarioMining.call(analysis: @analysis, membership: @membership, member_id: @scenario.cluster_member_id, reason: "é" * 2000).sole
      assert_equal @scenario.id, result.id
    end
    assert_equal definition, version.reload.attributes
    assert_equal review, version.latest_review.attributes
    assert version.approved?
  end

  test "nomination rejects absent malformed excessive or null-byte reasons and foreign or expired members atomically" do
    foreign_member_id = @scenario.cluster_member_id
    build_family_evidence_fixture
    member = @cluster.cluster_members.first
    assert_no_difference [ "Scenario.count", "ScenarioVersion.count", "ScenarioEvidence.count", "AuditEvent.count" ] do
      [ nil, "", "  ", "x" * 2001, "bad\0reason", { "reason" => "not a string" } ].each do |reason|
        assert_raises(Scenario::Invalid) { ScenarioMining.call(analysis: @analysis, membership: @membership, member_id: member.id, reason:) }
      end
      assert_raises(ActiveRecord::RecordNotFound) { ScenarioMining.call(analysis: @analysis, membership: @membership, member_id: foreign_member_id, reason: "Different corpus") }
      assert_raises(Current::RoleAccessDenied) { ScenarioMining.call(analysis: @analysis, membership: memberships(:outsider_beta), member_id: member.id, reason: "Foreign workspace") }
      @snapshot.source.update!(expires_at: 1.minute.ago)
      assert_raises(Scenario::Invalid) { ScenarioMining.call(analysis: @analysis, membership: @membership, member_id: member.id, reason: "Expired source") }
    end
  end

  test "expert versions freeze evidence and approval never carries to a changed version" do
    original = @scenario.current_version
    approve_scenario
    approved = @scenario.current_version
    assert approved.approved?
    assert_equal 2, approved.number
    assert_empty original.reload.requirements["outcomes"]
    assert_no_difference "ScenarioVersion.count" do
      assert_equal approved, @scenario.revise!(membership: @membership, base_version_id: approved.id, attributes: {})
    end
    revision = @scenario.revise!(membership: @membership, base_version_id: approved.id, attributes: { taxonomy_label: "SAML certificate setup", importance: "high" }, evidence_item_id: @knowledge.id, evidence_kind: "knowledge", excerpt: "Request the certificate expiry date.")
    assert_equal 3, revision.number
    assert_not revision.approved?
    assert approved.reload.approved?
    assert_equal 1, approved.scenario_evidence.count
    assert_equal 2, revision.scenario_evidence.count
    assert_equal @knowledge.source_snapshot, revision.scenario_evidence.find_by!(kind: "knowledge").corpus_item.source_snapshot
    assert_raises(Scenario::Invalid) { @scenario.revise!(membership: @membership, base_version_id: approved.id, attributes: { title: "Stale overwrite" }) }
    assert_raises(Scenario::Invalid) { @scenario.review!(membership: @membership, version_id: approved.id, decision: "reject") }
    assert_raises(ActiveRecord::ReadOnlyRecord) { approved.update!(title: "Rewrite") }
    assert_raises(ActiveRecord::StatementInvalid) do
      ScenarioVersion.transaction(requires_new: true) { ScenarioVersion.where(id: approved.id).update_all(title: "SQL rewrite") }
    end
  end

  test "expert replaces late historical conversation evidence without approval or target disclosure" do
    quote = "Inspect the signing certificate expiry date before any configuration change."
    snapshot = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Long export", kind: "conversations", bytes: [
      { id: "late", title: "SSO diagnostic history", content: "Shared preamble. " + " " * 4100 + quote }
    ].to_json)
    analysis = CorpusAnalysis.request!(corpus: @corpus, membership: @membership, scenario_limit: 3, processing_method: "local_full_text")
    CorpusAnalysisJob.perform_now(analysis.id)
    scenario = ScenarioMining.call(analysis:, membership: @membership).find { |candidate| candidate.corpus_item.source_snapshot_id == snapshot.id }
    approve_scenario(scenario)
    scenario.revise!(membership: @membership, base_version_id: scenario.current_version_id, attributes: {},
      evidence_item_id: @knowledge.id, evidence_kind: "knowledge", excerpt: @knowledge.content)
    scenario.review!(membership: @membership, version_id: scenario.current_version_id, decision: "approve")
    approved = scenario.current_version
    original_quote = approved.scenario_evidence.find_by!(kind: "expectation").excerpt
    visible = approved.target_input
    CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Long export", kind: "conversations", bytes: [
      { id: "late", title: "Changed export", content: "A newer answer must not replace historical evidence." }
    ].to_json)
    assert_not @corpus.current_items.exists?(scenario.corpus_item_id)
    revision = nil
    assert_no_difference [ "ScenarioReview.count", "HumanLabel.count", "ScenarioProposal.count", "EvaluationRun.count" ] do
      assert_difference [ "ScenarioVersion.count", "AuditEvent.count" ], 1 do
        assert_difference "ScenarioEvidence.count", 2 do
          revision = scenario.revise!(membership: @membership, base_version_id: approved.id, attributes: {}, conversation_excerpt: quote)
        end
      end
    end
    assert_equal quote, revision.scenario_evidence.find_by!(kind: "expectation").excerpt
    assert_equal snapshot.id, revision.scenario_evidence.find_by!(kind: "expectation").corpus_item.source_snapshot_id
    assert_equal @knowledge.content, revision.scenario_evidence.find_by!(kind: "knowledge").excerpt
    assert_equal visible, revision.target_input
    assert_equal approved.requirements, revision.requirements
    assert_equal @membership.user, revision.created_by
    assert_not revision.approved?
    assert_empty revision.scenario_reviews
    assert approved.reload.approved?
    assert_equal original_quote, approved.scenario_evidence.find_by!(kind: "expectation").excerpt
    assert_not_includes original_quote, quote
    assert_no_difference [ "ScenarioVersion.count", "ScenarioEvidence.count", "AuditEvent.count" ] do
      assert_equal revision, scenario.revise!(membership: @membership, base_version_id: revision.id, attributes: {}, conversation_excerpt: quote)
      assert_equal revision, scenario.revise!(membership: @membership, base_version_id: revision.id, attributes: {}, conversation_excerpt: "")
    end
  end

  test "conversation replacement validates exact retained text bounds authority and atomic attachment" do
    original = @scenario.current_version
    other_quote = (@scenarios - [ @scenario ]).sole.corpus_item.content
    assert_no_difference [ "ScenarioVersion.count", "ScenarioEvidence.count", "AuditEvent.count" ] do
      [ "Invented diagnosis", other_quote, "x" * 4001 ].each do |quote|
        assert_raises(ActiveRecord::RecordInvalid) do
          @scenario.revise!(membership: @membership, base_version_id: original.id, attributes: { title: "Must roll back" },
            conversation_excerpt: quote, evidence_item_id: @knowledge.id, evidence_kind: "knowledge", excerpt: @knowledge.content)
        end
      end
      assert_raises(Scenario::Invalid) { @scenario.revise!(membership: @membership, base_version_id: original.id, attributes: {}, conversation_excerpt: [ "Not text" ]) }
      assert_raises(Current::RoleAccessDenied) { @scenario.revise!(membership: memberships(:outsider_beta), base_version_id: original.id, attributes: {}, conversation_excerpt: "Customer") }
      assert_raises(Scenario::Invalid) { @scenario.revise!(membership: @membership, base_version_id: 0, attributes: {}, conversation_excerpt: "Customer") }
    end
    revision = @scenario.revise!(membership: @membership, base_version_id: original.id, attributes: {}, conversation_excerpt: "C",
      evidence_item_id: @knowledge.id, evidence_kind: "knowledge", excerpt: @knowledge.content)
    assert_equal "C", revision.scenario_evidence.find_by!(kind: "expectation").excerpt
    assert_equal @knowledge.content, revision.scenario_evidence.find_by!(kind: "knowledge").excerpt
    assert_equal @scenario.corpus_item.content, original.reload.scenario_evidence.sole.excerpt
    @snapshot.source.update!(expires_at: 1.minute.ago)
    assert_no_difference [ "ScenarioVersion.count", "ScenarioEvidence.count", "AuditEvent.count" ] do
      assert_raises(Scenario::Invalid) { @scenario.revise!(membership: @membership, base_version_id: revision.id, attributes: {}, conversation_excerpt: "Customer") }
    end
  end

  test "conversation replacement accepts the 4000 Unicode character edge but rejects 4001 exact characters" do
    text = "é " * 2000 + "é"
    snapshot = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Unicode history", kind: "conversations", bytes: [
      { id: "unicode", title: "Unicode record", content: text }
    ].to_json)
    analysis = CorpusAnalysis.request!(corpus: @corpus, membership: @membership, scenario_limit: 3)
    CorpusAnalysisJob.perform_now(analysis.id)
    scenario = ScenarioMining.call(analysis:, membership: @membership).find { |candidate| candidate.corpus_item.source_snapshot_id == snapshot.id }
    original = scenario.current_version
    short = scenario.revise!(membership: @membership, base_version_id: original.id, attributes: {}, conversation_excerpt: "é")
    boundary = scenario.revise!(membership: @membership, base_version_id: short.id, attributes: {}, conversation_excerpt: "é " * 2000)
    assert_equal "é", short.scenario_evidence.sole.excerpt
    assert_equal "é " * 2000, boundary.scenario_evidence.sole.excerpt
    assert_no_difference [ "ScenarioVersion.count", "ScenarioEvidence.count", "AuditEvent.count" ] do
      assert_equal boundary, scenario.revise!(membership: @membership, base_version_id: boundary.id, attributes: {}, conversation_excerpt: "é " * 2000)
      assert_raises(ActiveRecord::RecordInvalid) { scenario.revise!(membership: @membership, base_version_id: boundary.id, attributes: {}, conversation_excerpt: text) }
    end
    assert_equal "é " * 2000, scenario.reload.current_version.scenario_evidence.sole.excerpt
  end

  test "retained historical traces add distinct evidence without replacing records or inheriting approval" do
    approve_scenario
    approved = @scenario.current_version
    trace = JSON.parse(File.read(Rails.root.join("test/fixtures/files/production_traces.json"))).sole
    first = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Recurring failures", kind: "traces", bytes: [ trace ].to_json).corpus_items.sole
    second_trace = trace.deep_dup.merge("id" => "production-sso-74", "title" => "A later certificate failure")
    second_trace["input"]["known_facts"]["plan"] = "starter"
    refreshed = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Recurring failures", kind: "traces", bytes: [ trace, second_trace ].to_json)
    second = refreshed.corpus_items.find_by!(external_id: "production-sso-74")
    assert_not @corpus.current_items.exists?(first.id)
    assert_no_difference "Scenario.count" do
      revision = @scenario.revise!(membership: @membership, base_version_id: approved.id, attributes: {},
        evidence_item_id: first.id, evidence_kind: "expectation", excerpt: "The agent claimed a configuration change without collecting certificate evidence.")
      later = @scenario.revise!(membership: @membership, base_version_id: revision.id, attributes: {},
        evidence_item_id: second.id, evidence_kind: "expectation", excerpt: "Request the certificate expiry date first.")
      assert_equal [ @scenario.corpus_item_id, first.id, second.id ].sort, later.scenario_evidence.pluck(:corpus_item_id).sort
      assert_equal [ @scenario.corpus_item_id, first.id ].sort, revision.reload.scenario_evidence.pluck(:corpus_item_id).sort
      assert_equal approved.requirements, later.requirements
      assert_not later.approved?
      assert approved.reload.approved?
      assert_equal [ @scenario.corpus_item_id ], approved.scenario_evidence.pluck(:corpus_item_id)
    end
    CorpusIntake.call(corpus: @corpus, membership: @membership, name: "SSO playbook", kind: "document", bytes: "Current certificate guidance.")
    assert_raises(ActiveRecord::RecordNotFound) do
      @scenario.revise!(membership: @membership, base_version_id: @scenario.current_version_id, attributes: {},
        evidence_item_id: @knowledge.id, evidence_kind: "knowledge", excerpt: @knowledge.content)
    end
  end

  test "variants change one fact retain exact parent and cannot inherit approval" do
    approve_scenario
    parent = @scenario.current_version
    child = @scenario.variant!(membership: @membership, version_id: parent.id, variable: "plan", after: "starter", reason: "SSO is not an entitlement on starter.", expected_difference: "Explain the plan limit instead of recommending SAML setup.")
    version = child.current_version
    assert_equal parent, child.parent_version
    assert_equal({ "plan" => "starter", "idp" => "Okta" }, version.known_facts)
    assert_equal "enterprise", parent.reload.known_facts["plan"]
    assert_equal "enterprise", version.mutation["before"]
    assert_equal "starter", version.mutation["after"]
    assert_equal parent.scenario_evidence.pluck(:corpus_item_id), version.scenario_evidence.pluck(:corpus_item_id)
    assert_not version.approved?
    assert_raises(Scenario::Invalid) { child.review!(membership: @membership, version_id: version.id, decision: "approve") }
    assert_raises(Scenario::Invalid) { @scenario.variant!(membership: @membership, version_id: parent.id, variable: "plan", after: "enterprise", reason: "Same", expected_difference: "None") }
  end

  test "PostgreSQL retains integer and float JSON values including nested mutation evidence" do
    original = @scenario.current_version
    version = @scenario.scenario_versions.create!(original.attributes.except("id").merge(
      "number" => original.number + 1,
      "known_facts" => { "integer" => 0, "float" => 0.0, "nested" => [ { "integer" => 0, "float" => 0.0 } ] },
      "mutation" => { "before" => { "n" => [ 0 ] }, "after" => { "n" => [ 0.0 ] } })).reload
    assert_instance_of Integer, version.known_facts["integer"]
    assert_instance_of Float, version.known_facts["float"]
    assert_instance_of Integer, version.known_facts.dig("nested", 0, "integer")
    assert_instance_of Float, version.known_facts.dig("nested", 0, "float")
    assert_instance_of Integer, version.mutation.dig("before", "n", 0)
    assert_instance_of Float, version.mutation.dig("after", "n", 0)
  end

  test "typed JSON variants retain exact round trips and require expert revision and review" do
    approve_scenario
    facts = { "scalar" => 0, "nested" => { "z" => [ 7, { "n" => 0 } ], "a" => false }, "nullable" => nil, "ordered" => [ 1, 2 ] }
    parent = @scenario.revise!(membership: @membership, base_version_id: @scenario.current_version_id, attributes: { known_facts: facts }).reload
    @scenario.review!(membership: @membership, version_id: parent.id, decision: "approve")
    saved = parent.attributes
    evidence = parent.scenario_evidence.order(:id).pluck(:corpus_item_id, :kind, :excerpt)
    assert_instance_of Integer, parent.known_facts["scalar"]
    assert_instance_of Integer, parent.known_facts.dig("nested", "z", 1, "n")

    { "scalar" => 0.0, "nested" => { "a" => false, "z" => [ 7, { "n" => 0.0 } ] }, "nullable" => false, "ordered" => [ 2, 1 ] }.each do |variable, after|
      child = @scenario.variant!(membership: @membership, version_id: parent.id, variable:, after:,
        reason: "Author's mutation reason", expected_difference: "Author's expected difference, not an approved expectation")
      version = child.current_version.reload
      assert_equal parent.id, child.reload.parent_version_id
      assert parent.known_facts.merge(variable => after).eql?(version.known_facts)
      assert parent.known_facts[variable].eql?(version.mutation["before"])
      assert after.eql?(version.mutation["after"])
      assert_equal "Author's mutation reason", version.mutation["reason"]
      assert_equal "Author's expected difference, not an approved expectation", version.mutation["expected_difference"]
      assert_equal parent.requirements, version.requirements
      assert_equal evidence, version.scenario_evidence.order(:id).pluck(:corpus_item_id, :kind, :excerpt)
      assert_empty version.scenario_reviews
      assert_not version.approved?
      assert_raises(Scenario::Invalid) { child.review!(membership: @membership, version_id: version.id, decision: "approve") }
      revision = child.revise!(membership: @membership, base_version_id: version.id, attributes: { situation: "Expert checked this counterfactual starting situation." }).reload
      assert_equal "expert", revision.origin
      assert_not revision.approved?
      assert_equal version.mutation, revision.mutation
      child.review!(membership: @membership, version_id: revision.id, decision: "approve", note: "Expert checked the source-backed expectations.")
      assert revision.approved?
      assert_not version.reload.approved?
      assert_equal saved, parent.reload.attributes
      assert parent.approved?
    end

    assert_no_difference [ "Scenario.count", "ScenarioVersion.count", "AuditEvent.count" ] do
      reordered = { "a" => false, "z" => [ 7, { "n" => 0 } ] }
      assert_raises(Scenario::Invalid) do
        @scenario.variant!(membership: @membership, version_id: parent.id, variable: "nested", after: reordered, reason: "Order only", expected_difference: "None")
      end
    end
  end

  test "type-only direct revisions survive PostgreSQL without treating object order as a change" do
    approve_scenario
    before = { "scalar" => 0, "nested" => { "z" => [ 3, { "n" => 0 } ], "a" => nil } }
    parent = @scenario.revise!(membership: @membership, base_version_id: @scenario.current_version_id, attributes: { known_facts: before }).reload
    @scenario.review!(membership: @membership, version_id: parent.id, decision: "approve")
    saved = parent.attributes
    after = { "nested" => { "a" => nil, "z" => [ 3, { "n" => 0.0 } ] }, "scalar" => 0.0 }
    revision = nil
    assert_difference "ScenarioVersion.count", 1 do
      revision = @scenario.revise!(membership: @membership, base_version_id: parent.id, attributes: { known_facts: after }).reload
    end
    assert_instance_of Float, revision.known_facts["scalar"]
    assert_instance_of Float, revision.known_facts.dig("nested", "z", 1, "n")
    assert after.eql?(revision.known_facts)
    assert_equal "expert", revision.origin
    assert_not revision.approved?
    assert_equal saved, parent.reload.attributes
    assert parent.approved?
    assert_equal parent.scenario_evidence.pluck(:corpus_item_id, :kind, :excerpt), revision.scenario_evidence.pluck(:corpus_item_id, :kind, :excerpt)
    assert_no_difference [ "ScenarioVersion.count", "AuditEvent.count" ] do
      reordered = { "scalar" => 0.0, "nested" => { "z" => [ 3, { "n" => 0.0 } ], "a" => nil } }
      assert_equal revision, @scenario.revise!(membership: @membership, base_version_id: revision.id, attributes: { known_facts: reordered })
    end
  end

  test "reject and merge retain decisions and block invalid merge destinations" do
    other = (@scenarios - [ @scenario ]).sole
    @scenario.review!(membership: @membership, version_id: @scenario.current_version_id, decision: "reject", note: "Missing context.")
    assert_equal "reject", @scenario.current_version.latest_review.decision
    assert_raises(Scenario::Invalid) { @scenario.review!(membership: @membership, version_id: @scenario.current_version_id, decision: "merge", merge_into_id: other.id) }
    approve_scenario(other)
    review = @scenario.review!(membership: @membership, version_id: @scenario.current_version_id, decision: "merge", merge_into_id: other.id, note: "Same required escalation.")
    assert_equal other, @scenario.reload.merged_into
    assert_equal other.current_version, review.merged_version
    assert_equal 2, @scenario.current_version.scenario_reviews.count
    assert_raises(Scenario::Invalid) { @scenario.revise!(membership: @membership, base_version_id: @scenario.current_version_id, attributes: { title: "Edited after merge" }) }
    assert_raises(Scenario::Invalid) { other.review!(membership: @membership, version_id: other.current_version_id, decision: "merge", merge_into_id: other.id) }
  end

  test "invalid evidence and definitions roll back whole revisions and foreign pointers fail" do
    foreign_corpus = workspaces(:beta_support).corpora.create!(name: "Other company")
    foreign = CorpusIntake.call(corpus: foreign_corpus, membership: memberships(:outsider_beta), name: "Private", kind: "document", bytes: "Private data").corpus_items.sole
    assert_raises(ActiveRecord::RecordNotFound) { @scenario.revise!(membership: @membership, base_version_id: @scenario.current_version_id, attributes: {}, evidence_item_id: foreign.id, evidence_kind: "knowledge", excerpt: "Private data") }
    assert_no_difference "ScenarioVersion.count" do
      assert_raises(ActiveRecord::RecordInvalid) { @scenario.revise!(membership: @membership, base_version_id: @scenario.current_version_id, attributes: {}, evidence_item_id: @knowledge.id, evidence_kind: "knowledge", excerpt: "Invented evidence") }
      assert_raises(ActiveRecord::RecordInvalid) { @scenario.revise!(membership: @membership, base_version_id: @scenario.current_version_id, attributes: { known_facts: [] }) }
    end
    assert_raises(ActiveRecord::InvalidForeignKey) do
      Scenario.transaction(requires_new: true) { @scenario.update!(current_version: (@scenarios - [ @scenario ]).sole.current_version) }
    end
    assert_raises(ActiveRecord::InvalidForeignKey) do
      ScenarioEvidence.transaction(requires_new: true) { @scenario.current_version.scenario_evidence.create!(workspace: @workspace, corpus: @corpus, corpus_item: foreign, kind: "knowledge", excerpt: "Private data") }
    end
    assert_raises(Current::RoleAccessDenied) { @scenario.review!(membership: memberships(:outsider_beta), version_id: @scenario.current_version_id, decision: "reject") }
  end

  test "updated guidance marks fixed evidence stale and expiry and purge hide or delete derivatives" do
    approve_scenario
    child = @scenario.variant!(membership: @membership, version_id: @scenario.current_version_id, variable: "plan", after: "starter", reason: "Plan limit", expected_difference: "Different entitlement")
    revision = @scenario.revise!(membership: @membership, base_version_id: @scenario.current_version_id, attributes: {}, evidence_item_id: @knowledge.id, evidence_kind: "knowledge", excerpt: "Request the certificate expiry date.")
    CorpusIntake.call(corpus: @corpus, membership: @membership, name: "SSO playbook", kind: "document", bytes: "New policy: request current IdP metadata.")
    assert revision.stale?
    assert_equal "Request the certificate expiry date.", revision.scenario_evidence.find_by!(kind: "knowledge").excerpt
    current_doc = @corpus.current_items.joins(source_snapshot: :source).where(sources: { name: "SSO playbook" }).sole
    refreshed = @scenario.revise!(membership: @membership, base_version_id: revision.id, attributes: {}, evidence_item_id: current_doc.id, evidence_kind: "knowledge", excerpt: current_doc.content)
    assert_not refreshed.stale?
    assert revision.reload.stale?
    assert_equal 2, refreshed.scenario_evidence.count
    travel 366.days do
      assert revision.expired?
      error = assert_raises(Scenario::Invalid) { @scenario.review!(membership: @membership, version_id: refreshed.id, decision: "reject") }
      assert_equal "Source evidence expired.", error.message
    end
    SourcePurge.call(source: @knowledge.source_snapshot.source, membership: @membership)
    assert_not Scenario.exists?(@scenario.id)
    assert_not Scenario.exists?(child.id)
    assert_empty ScenarioVersion.where(corpus: @corpus)
    assert_empty ScenarioReview.where(corpus: @corpus)
    assert_empty ScenarioEvidence.where(corpus: @corpus)
    assert CorpusItem.exists?(@scenario.corpus_item_id)
  end
end
