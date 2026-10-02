require "test_helper"
require_relative "../test_helpers/scenario_test_helper"

class ScenarioTest < ActiveSupport::TestCase
  include ScenarioTestHelper

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
