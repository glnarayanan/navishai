require "test_helper"
require_relative "../support/failure_matching_fixture"

class TraceScenarioDecisionTest < ActiveSupport::TestCase
  include FailureMatchingFixture
  setup { build_failure_matching_fixture }

  test "corrections append per expert without approving editing executing or labelling" do
    other = Membership.create!(workspace: @corpus.workspace, user: users(:teammate), role: :member)
    assert_no_difference [ "ScenarioVersion.count", "ScenarioReview.count", "EvalCase.count", "EvaluationRun.count", "HumanLabel.count" ] do
      first = append_decision
      second = append_decision(membership: other, decision: "different")
      correction = append_decision(decision: "uncertain", reason: "Need certificate logs.")
      assert_equal [ correction.id, first.id ], TraceScenarioDecision.where(reviewed_by: @membership.user).order(id: :desc).pluck(:id)
      assert_equal "different", second.reload.decision
      assert_not @version.approved?
      assert_raises(ActiveRecord::ReadOnlyRecord) { first.update!(reason: "replace") }
      assert_raises(ActiveRecord::StatementInvalid) do
        TraceScenarioDecision.transaction(requires_new: true) { TraceScenarioDecision.where(id: first.id).update_all(reason: "replace") }
      end
    end
    assert_equal({}, AuditEvent.where(action: "trace.scenario_decided").last.metadata)
  end

  test "stale rejected merged foreign viewer and expired decisions save nothing" do
    viewer = Membership.create!(workspace: @corpus.workspace, user: users(:teammate), role: :viewer)
    assert_raises(Current::RoleAccessDenied) { append_decision(membership: viewer) }
    foreign = @corpus.workspace.corpora.create!(name: "Other corpus")
    assert_raises(Scenario::Invalid) { append_decision(version: ScenarioVersion.new(corpus: foreign, workspace: foreign.workspace)) }
    assert_raises(Current::RoleAccessDenied) { append_decision(membership: memberships(:outsider_beta)) }
    @version.scenario.revise!(membership: @membership, base_version_id: @version.id, attributes: { title: "New certificate version" })
    assert_raises(Scenario::Invalid) { append_decision }
    @version = @version.scenario.reload.current_version
    @version.scenario.review!(membership: @membership, version_id: @version.id, decision: "reject")
    assert_raises(Scenario::Invalid) { append_decision }
    @version = matching_version
    @version.scenario.update!(merged_into: matching_version.scenario)
    assert_raises(Scenario::Invalid) { append_decision }
    @version = matching_version
    CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Certificate policy", kind: "document", bytes: "Changed policy")
    assert_raises(Scenario::Invalid) { append_decision }
    @item.source_snapshot.source.update!(expires_at: 1.minute.ago)
    assert_raises(CorpusIntake::Invalid) { append_decision }
    assert_empty TraceScenarioDecision.where(corpus: @corpus)
  end

  test "composite foreign keys prohibit rebinding and purge cascades decisions" do
    record = append_decision
    foreign = @corpus.workspace.corpora.create!(name: "Foreign")
    values = record.attributes.except("id").merge("corpus_id" => foreign.id)
    assert_raises(ActiveRecord::InvalidForeignKey) do
      TraceScenarioDecision.transaction(requires_new: true) { TraceScenarioDecision.insert_all!([ values ]) }
    end
    values = record.attributes.except("id").merge("workspace_id" => workspaces(:beta_support).id)
    assert_raises(ActiveRecord::InvalidForeignKey) do
      TraceScenarioDecision.transaction(requires_new: true) { TraceScenarioDecision.insert_all!([ values ]) }
    end
    SourcePurge.call(source: @document.source_snapshot.source, membership: @membership)
    assert_not TraceScenarioDecision.exists?(record.id)
  end

  test "trace identity and a reported failure are required and expiry purge deletes history" do
    original = @item
    @item = @document
    assert_raises(CorpusIntake::Invalid) { append_decision }
    @item = original
    traces = JSON.parse(File.read(Rails.root.join("test/fixtures/files/production_traces.json")))
    traces.sole["observed_failure"] = ""
    @item = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "No failure", kind: "traces", bytes: traces.to_json).corpus_items.sole
    assert_raises(Scenario::Invalid) { append_decision }
    @item = original
    record = append_decision
    source = @item.source_snapshot.source
    source.update!(expires_at: 1.minute.ago)
    assert_empty TraceScenarioMatching.call(item: @item).candidates
    SourcePurge.call(source:)
    assert_not TraceScenarioDecision.exists?(record.id)
  end
end
