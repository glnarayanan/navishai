require "test_helper"
require_relative "../test_helpers/scenario_test_helper"

class ScenarioVariantTest < ActiveSupport::TestCase
  include ScenarioTestHelper
  include ActiveJob::TestHelper

  setup do
    build_scenarios
    approve_scenario
    @facts = { "plan" => "enterprise", "role" => "admin", "idp" => "Okta", "incident" => false,
      "environment" => { "attempts" => [ 0, nil ], "region" => "eu" } }
    @parent = @scenario.revise!(membership: @membership, base_version_id: @scenario.current_version_id,
      attributes: { known_facts: @facts, hidden_facts: { "answer" => "parent-only-answer" },
        follow_ups: [ { "after_assistant_contains" => "expiry", "message" => "parent-only-follow-up" } ] },
      evidence_item_id: @knowledge.id, evidence_kind: "knowledge", excerpt: "Request the certificate expiry date.").reload
    @scenario.review!(membership: @membership, version_id: @parent.id, decision: "approve")
    @changes = { "plan" => "starter", "role" => "non-admin", "idp" => "Entra", "incident" => true,
      "environment" => { "region" => "eu", "attempts" => [ 0.0, false ] } }
  end

  test "coupled typed counterfactuals keep exact receipts and evidence but no parent answers or authority" do
    saved = @parent.attributes
    evidence = @parent.scenario_evidence.order(:id).pluck(:corpus_item_id, :kind, :excerpt)
    child = nil
    assert_no_enqueued_jobs do
      assert_no_difference [ "ScenarioReview.count", "HumanLabel.count", "EvalCase.count", "ScenarioProposal.count" ] do
        assert_difference [ "Scenario.count", "ScenarioVersion.count", "AuditEvent.count" ], 1 do
          child = variant
        end
      end
    end
    version = child.current_version.reload
    assert_equal @parent.id, child.parent_version_id
    assert_equal @scenario.corpus_item_id, child.corpus_item_id
    assert @facts.merge(@changes).eql?(version.known_facts)
    assert_equal({ "changes" => [
      { "variable" => "plan", "before" => "enterprise", "after" => "starter" },
      { "variable" => "role", "before" => "admin", "after" => "non-admin" },
      { "variable" => "idp", "before" => "Okta", "after" => "Entra" },
      { "variable" => "incident", "before" => false, "after" => true },
      { "variable" => "environment", "before" => { "attempts" => [ 0, nil ], "region" => "eu" }, "after" => { "region" => "eu", "attempts" => [ 0.0, false ] } }
    ], "reason" => "Author tests a coupled entitlement and incident boundary.",
      "expected_difference" => "Proposed difference only: check access and incident evidence before SAML setup." }, version.mutation)
    assert_instance_of Integer, version.mutation.dig("changes", 4, "before", "attempts", 0)
    assert_instance_of Float, version.mutation.dig("changes", 4, "after", "attempts", 0)
    assert_equal evidence, version.scenario_evidence.order(:id).pluck(:corpus_item_id, :kind, :excerpt)
    assert_equal @parent.draft_notes, version.draft_notes
    assert_equal ScenarioVersion::REQUIREMENT_TYPES.index_with { [] }, version.requirements
    assert_empty version.hidden_facts
    assert_empty version.follow_ups
    assert_empty version.scenario_reviews
    assert_not version.approved?
    assert_equal({ "situation" => @parent.situation, "known_facts" => @facts.merge(@changes),
      "knowledge" => [ { "reference" => "corpus-item-#{@knowledge.id}", "content" => "Request the certificate expiry date." } ] }, version.target_input)
    %w[mutation draft_notes requirements hidden_facts expected_difference].each { |key| assert_not version.target_input.key?(key) }
    assert_not_includes version.target_input.to_json, "parent-only-answer"
    assert_not_includes version.target_input.to_json, "parent-only-follow-up"
    assert_raises(Scenario::Invalid) { child.review!(membership: @membership, version_id: version.id, decision: "approve") }
    assert_raises(EvalCase::Invalid) { EvalCompiler.call(scenario: child, membership: @membership, version_id: version.id, checks: []) }
    assert_equal saved, @parent.reload.attributes
    assert @parent.approved?
    assert_equal({ "version" => 1 }, AuditEvent.where(action: "scenario.variant_created", subject_id: version.id).sole.metadata)
  end

  test "fresh expert outcomes and separate review are required after a controlled set" do
    child = variant
    original = child.current_version
    renamed = child.revise!(membership: @membership, base_version_id: original.id, attributes: { title: "Renamed counterfactual" })
    assert_raises(Scenario::Invalid) { child.review!(membership: @membership, version_id: renamed.id, decision: "approve") }
    requirements = ScenarioVersion::REQUIREMENT_TYPES.index_with { [] }.merge("outcomes" => [ "Establish current metadata evidence before proposing a change." ])
    expert = child.revise!(membership: @membership, base_version_id: renamed.id, attributes: { situation: "A non-admin on starter reports Entra login failure during a reported incident.", requirements: })
    assert_empty expert.scenario_reviews
    assert_not expert.approved?
    review = child.review!(membership: @membership, version_id: expert.id, decision: "approve", note: "Checked the counterfactual and evidence.")
    assert_equal expert.id, review.scenario_version_id
    assert_equal @membership.user.id, review.reviewed_by_id
    assert expert.reload.approved?
    assert_not original.reload.approved?
    assert_equal original.mutation, expert.mutation
    assert_equal original.draft_notes, expert.draft_notes
    assert_empty original.requirements["outcomes"]
  end

  test "one invalid member no-op ambiguous input or oversized receipt refuses the entire set" do
    assert_no_difference [ "Scenario.count", "ScenarioVersion.count", "ScenarioEvidence.count", "AuditEvent.count" ] do
      [ {}, [], nil, { "new_fact" => true }, @changes.merge("unknown" => false),
        { "plan" => "starter", "idp" => "Okta" }, { "environment" => { "region" => "eu", "attempts" => [ 0, nil ] } } ].each do |changes|
        assert_raises(Scenario::Invalid) { variant(changes:) }
      end
      assert_raises(Scenario::Invalid) { variant(variable: "plan", after: "starter") }
      [ "", "  ", " " * 2000 + "x", "雪" * 2001, "bad\0reason", {} ].each do |reason|
        assert_raises(Scenario::Invalid) { variant(reason:) }
        assert_raises(Scenario::Invalid) { variant(expected_difference: reason) }
      end
      assert_raises(ActiveRecord::RecordInvalid) { variant(changes: { "plan" => "雪" * 4000 }) }
    end
    @parent = @scenario.revise!(membership: @membership, base_version_id: @parent.id, attributes: { known_facts: @facts.merge("suspended" => false) })
    @scenario.review!(membership: @membership, version_id: @parent.id, decision: "approve")
    assert_no_difference [ "Scenario.count", "ScenarioVersion.count", "ScenarioEvidence.count", "AuditEvent.count" ] do
      assert_raises(Scenario::Invalid) { variant(changes: @changes.merge("suspended" => true)) }
    end
    wide = @scenario.revise!(membership: @membership, base_version_id: @parent.id, attributes: { known_facts: { "large" => "x" * 6000 } })
    @scenario.review!(membership: @membership, version_id: wide.id, decision: "approve")
    assert_no_difference [ "Scenario.count", "ScenarioVersion.count", "ScenarioEvidence.count", "AuditEvent.count" ] do
      assert_raises(ActiveRecord::RecordInvalid) { variant(version_id: wide.id, changes: { "large" => "y" * 6000 }) }
    end
  end

  test "receipt allows the exact ten KiB boundary and rejects one further byte atomically" do
    @parent = @scenario.revise!(membership: @membership, base_version_id: @parent.id, attributes: { known_facts: { "plan" => "enterprise" } })
    @scenario.review!(membership: @membership, version_id: @parent.id, decision: "approve")
    receipt = { "changes" => [ { "variable" => "plan", "before" => "enterprise", "after" => "" } ], "reason" => "R", "expected_difference" => "D" }
    value = "x" * (10.kilobytes - receipt.to_json.bytesize)
    child = variant(changes: { "plan" => value }, reason: "R", expected_difference: "D")
    assert_equal 10.kilobytes, child.current_version.reload.mutation.to_json.bytesize
    assert_equal value, child.current_version.mutation.dig("changes", 0, "after")
    assert_no_difference [ "Scenario.count", "ScenarioVersion.count", "ScenarioEvidence.count", "AuditEvent.count" ] do
      assert_raises(ActiveRecord::RecordInvalid) { variant(changes: { "plan" => value + "x" }, reason: "R", expected_difference: "D") }
    end
  end

  test "current approval tenant access and every linked source lifetime gate variant creation" do
    assert_no_difference [ "Scenario.count", "ScenarioVersion.count", "ScenarioEvidence.count", "AuditEvent.count" ] do
      assert_raises(Current::RoleAccessDenied) { variant(membership: memberships(:outsider_beta)) }
      viewer = Membership.create!(workspace: @workspace, user: users(:teammate), role: :viewer)
      assert_raises(Current::RoleAccessDenied) { variant(membership: viewer) }
      assert_raises(Scenario::Invalid) { variant(version_id: @scenario.scenario_versions.find_by!(number: 1).id) }
      @knowledge.source_snapshot.source.update!(expires_at: 1.minute.ago)
      assert_raises(Scenario::Invalid) { variant }
      @knowledge.source_snapshot.source.update!(expires_at: 1.year.from_now)
    end
    CorpusIntake.call(corpus: @corpus, membership: @membership, name: "SSO playbook", kind: "document", bytes: "Changed guidance.")
    assert_no_difference [ "Scenario.count", "ScenarioVersion.count", "ScenarioEvidence.count", "AuditEvent.count" ] do
      assert @parent.stale?
      assert_raises(Scenario::Invalid) { variant }
    end
    revision = @scenario.revise!(membership: @membership, base_version_id: @parent.id, attributes: { title: "Unreviewed revision" })
    assert_no_difference "Scenario.count" do
      assert_raises(Scenario::Invalid) { variant(version_id: revision.id) }
    end
  end

  test "SQL freezes parent mutation and evidence and enforces same-corpus parent lineage" do
    child = variant
    version = child.current_version
    assert_raises(ActiveRecord::ReadonlyAttributeError) { child.update!(parent_version_id: nil) }
    [ -> { Scenario.where(id: child.id).update_all(parent_version_id: nil) },
      -> { ScenarioVersion.where(id: version.id).update_all(mutation: {}) },
      -> { ScenarioEvidence.where(scenario_version_id: version.id).update_all(excerpt: "Changed evidence") } ].each do |write|
      assert_raises(ActiveRecord::StatementInvalid) { Scenario.transaction(requires_new: true) { write.call } }
    end
    attributes = child.attributes.except("id").merge("current_version_id" => nil)
    other_corpus = @workspace.corpora.create!(name: "Different corpus")
    item = CorpusIntake.call(corpus: other_corpus, membership: @membership, name: "Other conversation", kind: "conversations",
      bytes: [ { id: "other", title: "Other", content: "Other source text." } ].to_json).corpus_items.sole
    assert_raises(ActiveRecord::InvalidForeignKey) do
      Scenario.transaction(requires_new: true) { Scenario.insert_all!([ attributes.merge("corpus_id" => other_corpus.id, "corpus_item_id" => item.id) ]) }
    end
    assert_raises(ActiveRecord::InvalidForeignKey) do
      Scenario.transaction(requires_new: true) { ScenarioVersion.insert_all!([ version.attributes.except("id").merge("number" => 2, "workspace_id" => workspaces(:beta_support).id) ]) }
    end
    @snapshot.source.update!(expires_at: 1.minute.ago)
    assert version.expired?
    assert_raises(Scenario::Invalid) { child.revise!(membership: @membership, base_version_id: version.id, attributes: { title: "Expired" }) }
    SourcePurge.call(source: @snapshot.source, membership: @membership)
    assert_not Scenario.exists?(child.id)
    assert_not ScenarioVersion.exists?(version.id)
    assert_empty ScenarioEvidence.where(scenario_version_id: version.id)
    assert_equal({ "version" => 1 }, AuditEvent.where(action: "scenario.variant_created", subject_id: version.id).sole.metadata)
  end

  test "runtime grants allow variants fresh review and purge but cannot change the parent receipt" do
    connection = ActiveRecord::Base.connection
    skip "Runtime grant proof requires a role-preparation test connection." unless connection.select_value("SELECT rolsuper OR rolcreaterole FROM pg_roles WHERE rolname = current_user")
    role = connection.quote_column_name("scenario_variant_#{SecureRandom.hex(6)}")
    connection.transaction(requires_new: true) do
      connection.execute("CREATE ROLE #{role} NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS")
      connection.execute("GRANT USAGE ON SCHEMA public TO #{role}")
      connection.execute("GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO #{role}")
      connection.execute("GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO #{role}")
      connection.execute("SET LOCAL ROLE #{role}")
      child = variant
      original = child.current_version
      assert_raises(ActiveRecord::StatementInvalid) do
        connection.transaction(requires_new: true) { Scenario.where(id: child.id).update_all(parent_version_id: nil) }
      end
      expert = child.revise!(membership: @membership, base_version_id: original.id, attributes: {
        requirements: ScenarioVersion::REQUIREMENT_TYPES.index_with { [] }.merge("outcomes" => [ "Collect current certificate evidence." ]) })
      child.review!(membership: @membership, version_id: expert.id, decision: "approve")
      assert expert.reload.approved?
      assert_equal original.mutation, expert.mutation
      SourcePurge.call(source: @snapshot.source, membership: @membership)
      assert_not Scenario.exists?(child.id)
      assert_not ScenarioVersion.exists?(original.id)
      assert_not ScenarioVersion.exists?(expert.id)
      connection.execute("RESET ROLE")
      raise ActiveRecord::Rollback
    end
  end

  private
    def variant(**options)
      @scenario.variant!(**{ membership: @membership, version_id: @parent.id, changes: @changes,
        reason: "Author tests a coupled entitlement and incident boundary.",
        expected_difference: "Proposed difference only: check access and incident evidence before SAML setup." }.merge(options))
    end
end
