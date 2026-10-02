require "test_helper"
require_relative "../test_helpers/family_evidence_fixture"

class IssueClusterTest < ActiveSupport::TestCase
  include FamilyEvidenceFixture
  setup { build_family_evidence_fixture }

  test "exact booleans and full family denominators do not coerce source reports" do
    groups = @cluster.source_groups
    assert_equal 55, groups.fetch("All records").size
    { "escalated" => [ 2, 1, 52 ], "reopened" => [ 1, 2, 52 ], "failed" => [ 2, 1, 52 ] }.each do |field, counts|
      assert_equal counts, [ "true", "false", "missing / nonboolean" ].map { |state| groups.fetch("context.#{field}: #{state}").size }
      assert_equal @items[2..5].map(&:id), groups.fetch("context.#{field}: missing / nonboolean").first(4).map(&:corpus_item_id)
    end
    assert_equal [ @items.first.id ], groups.fetch("reported critical impact").map(&:corpus_item_id)
  end

  test "overlapping literal mentions are distinct from reports and diagnostic evidence is not risk" do
    groups = @cluster.source_groups
    assert_equal 55, groups.fetch("diagnostic evidence mention").size
    assert_equal [ @items[0].id, @items[50].id ], groups.fetch("risk mention").map(&:corpus_item_id)
    assert_equal [ @items[0].id ], groups.fetch("escalation mention").map(&:corpus_item_id)
    assert_equal [ @items[0].id ], groups.fetch("reopen / unresolved mention").map(&:corpus_item_id)
    assert_includes groups.fetch("context.escalated: false").map(&:corpus_item_id), @items[1].id
    assert_not_includes groups.fetch("risk mention").map(&:corpus_item_id), @items[1].id
    assert_equal [ "critical importance proposal" ], @cluster.cluster_members.first.signals
  end

  test "local and model rules match and later export cannot replace fixed inputs" do
    _, model = build_fixed_family(ModelCorpusDiscovery::VERSION)
    expected = @cluster.source_groups.transform_values { |members| members.map(&:corpus_item_id) }
    assert_equal expected, model.source_groups.transform_values { |members| members.map(&:corpus_item_id) }
    refresh_family_export
    assert_equal expected, @cluster.reload.source_groups.transform_values { |members| members.map(&:corpus_item_id) }
    assert_equal expected, model.reload.source_groups.transform_values { |members| members.map(&:corpus_item_id) }
  end

  test "separately valid uploads cannot bypass the full text and context byte bound" do
    2.times do |index|
      snapshot = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Wide context #{index}", kind: "conversations",
        bytes: [ { id: "wide-#{index}", title: "Diagnostics", content: "Collect logs.", context: { notes: "x" * 6.megabytes } } ].to_json)
      item = snapshot.corpus_items.sole
      @analysis.corpus_analysis_inputs.create!(workspace: @workspace, corpus: @corpus, corpus_item: item)
      @cluster.cluster_members.create!(workspace: @workspace, corpus: @corpus, corpus_item: item, signals: [])
    end
    assert_operator @cluster.cluster_members.joins(:corpus_item).sum("octet_length(corpus_items.content)"), :<, 10.megabytes
    assert_raises(ActiveRecord::RecordNotFound) { @cluster.source_groups }
  end

  test "expiry of any fixed analysis input blocks inspection even outside the family" do
    document = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Policy", kind: "document", bytes: "Policy.")
    @analysis.corpus_analysis_inputs.create!(workspace: @workspace, corpus: @corpus, corpus_item: document.corpus_items.sole)
    document.source.update!(expires_at: 1.minute.ago)
    assert_raises(ActiveRecord::RecordNotFound) { @cluster.source_groups }
  end
end
