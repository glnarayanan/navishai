require "test_helper"
require_relative "../test_helpers/scenario_test_helper"

class SourceImpactTest < ActiveSupport::TestCase
  include ScenarioTestHelper

  setup { build_scenarios }

  test "exact source snapshots separate historical and current dependencies without rewriting evidence" do
    source = @snapshot.source
    original = @scenario.current_version
    approve_scenario
    current = @scenario.current_version
    other = (@scenarios - [ @scenario ]).sole.current_version
    original_evidence = original.scenario_evidence.pluck(:corpus_item_id, :excerpt)
    current_evidence = current.scenario_evidence.pluck(:corpus_item_id, :excerpt)

    relation = source.dependent_versions(snapshot: @snapshot)
    assert_kind_of ActiveRecord::Relation, relation
    assert_equal [ original.id, current.id, other.id ].sort, relation.pluck(:id).sort
    assert_empty @knowledge.source_snapshot.source.dependent_versions(snapshot: @knowledge.source_snapshot)

    updated = CorpusIntake.call(corpus: @corpus, membership: @membership, name: source.name, kind: "conversations",
      bytes: [ { id: "new", title: "New billing question", content: "An unrelated invoice needs explanation." } ].to_json)
    assert_not_equal @snapshot.id, updated.id
    assert_empty source.dependent_versions(snapshot: updated)
    assert_equal [ original.id, current.id, other.id ].sort, source.dependent_versions(snapshot: @snapshot).pluck(:id).sort
    assert_equal original_evidence, original.reload.scenario_evidence.pluck(:corpus_item_id, :excerpt)
    assert_equal current_evidence, current.reload.scenario_evidence.pluck(:corpus_item_id, :excerpt)
    assert_not original.stale?
    assert_not current.stale?
  end

  test "multiple evidence links return each dependent version once" do
    version = @scenario.current_version
    version.scenario_evidence.create!(workspace: @workspace, corpus: @corpus,
      corpus_item: @scenario.corpus_item, kind: "knowledge", excerpt: "Request the expiry date")

    ids = @snapshot.source.dependent_versions(snapshot: @snapshot).pluck(:id)
    assert_equal 1, ids.count(version.id)
    assert_equal @scenarios.map(&:current_version_id).sort, ids.sort
  end

  test "changed documents retain stale dependencies while new evidence belongs only to its snapshot" do
    old_snapshot = @knowledge.source_snapshot
    source = old_snapshot.source
    dependent = @scenario.revise!(membership: @membership, base_version_id: @scenario.current_version_id,
      attributes: {}, evidence_item_id: @knowledge.id, evidence_kind: "knowledge", excerpt: @knowledge.content)
    fixed_evidence = dependent.scenario_evidence.pluck(:corpus_item_id, :excerpt)
    updated = CorpusIntake.call(corpus: @corpus, membership: @membership, name: source.name,
      kind: "document", bytes: "Request current IdP metadata before investigating authentication.")

    assert_equal [ dependent.id ], source.dependent_versions(snapshot: old_snapshot).pluck(:id)
    assert_empty source.dependent_versions(snapshot: updated)
    assert dependent.stale?
    assert_equal fixed_evidence, dependent.reload.scenario_evidence.pluck(:corpus_item_id, :excerpt)

    item = updated.corpus_items.sole
    refreshed = @scenario.revise!(membership: @membership, base_version_id: dependent.id,
      attributes: {}, evidence_item_id: item.id, evidence_kind: "knowledge", excerpt: item.content)
    assert_equal [ dependent.id ], source.dependent_versions(snapshot: old_snapshot).pluck(:id)
    assert_equal [ refreshed.id ], source.dependent_versions(snapshot: updated).pluck(:id)
    assert_equal [ dependent.id, refreshed.id ].sort, source.dependent_versions.pluck(:id).sort
    assert_not refreshed.stale?
    assert dependent.reload.stale?
  end

  test "snapshots from another source or corpus are rejected" do
    source = @snapshot.source
    assert_raises(ActiveRecord::RecordNotFound) { source.dependent_versions(snapshot: @knowledge.source_snapshot) }
    foreign_corpus = workspaces(:beta_support).corpora.create!(name: "Other impact corpus")
    foreign = CorpusIntake.call(corpus: foreign_corpus, membership: memberships(:outsider_beta),
      name: source.name, kind: "document", bytes: "Private policy.")
    assert_raises(ActiveRecord::RecordNotFound) { source.dependent_versions(snapshot: foreign) }
  end

  test "current retention hides dependencies even when source and corpus associations were cached" do
    source = @snapshot.source
    source.corpus.sources.load
    assert_not_empty source.dependent_versions(snapshot: @snapshot)
    Source.find(source.id).update!(expires_at: 1.minute.ago)
    assert source.expires_at > Time.current
    assert_empty source.dependent_versions(snapshot: @snapshot)

    Source.find(source.id).update!(expires_at: 1.year.from_now)
    assert_not_empty source.dependent_versions(snapshot: @snapshot)
    Source.find(@knowledge.source_snapshot.source_id).update!(expires_at: 1.minute.ago)
    assert_empty source.dependent_versions(snapshot: @snapshot)
  end
end
