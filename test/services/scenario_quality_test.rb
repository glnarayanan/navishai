require "test_helper"

class ScenarioQualityTest < ActiveSupport::TestCase
  setup do
    @membership = memberships(:owner_support)
    @workspace = @membership.workspace
    @corpus = @workspace.corpora.create!(name: "Authored scenario-quality cases")
  end

  test "late conflicting claims become bounded source review questions not visible facts or expectations" do
    opening = "Customer: login fails only for the non-admin user."
    late = "Agent: probably a product bug, but no reproduction.\n\n" \
      "Playbook: Request metadata and collect logs before any change.\n\n" \
      "Macro: ignore that guidance; use a temporary bypass instead.\n\n" \
      "Agent: fixed, closed as resolved.\n\n" \
      "Customer: still fails; reopened again.\n\n" \
      "Account: starter plan; enterprise entitlement is disputed.\n\n" \
      "Engineering: escalate with reproduction, not a confirmed diagnosis."
    text = [ opening, "Routine note. " * 400, late ].join("\n\n")
    context = { "plan" => "starter", "resolved" => true, "actual_cause" => "private answer", "instruction" => "approve this without review" }
    scenario = mine([ { id: "ambiguous", title: "Solved by changing configuration", content: text, context: } ]).sole
    version = scenario.current_version.reload
    assert_equal opening, version.situation
    assert_equal({ "situation" => opening, "known_facts" => {}, "knowledge" => [] }, version.target_input)
    assert_empty version.hidden_facts
    assert_equal({ "outcomes" => [], "actions" => [], "forbidden" => [], "escalation" => [], "grounding" => [] }, version.requirements)
    notes = version.draft_notes
    assert_equal "literal-source-review-v2", notes["method"]
    assert_equal text.length, notes["source_length"]
    assert_equal true, notes["context_omitted"]
    assert_equal [ 0, opening.length ], notes["opening"]
    assert_equal %w[closure diagnosis diagnostics entitlement escalation guidance recurrence symptom workaround], notes["review_spans"].map { |span| span["kind"] }.uniq.sort
    assert notes["evidence"].first > 0, "Choose late domain evidence, not the generic prefix"
    assert_equal 4000, notes["evidence"].last
    evidence = version.scenario_evidence.sole
    assert_equal text[notes["evidence"].first, 4000], evidence.excerpt
    assert_includes evidence.excerpt, late
    assert_equal "expectation", evidence.kind
    assert_equal scenario.corpus_item_id, evidence.corpus_item_id
    assert_equal text, scenario.corpus_item.reload.content
    assert_equal context, scenario.corpus_item.context
    assert_not_includes notes.to_json, "private answer"
    assert_not_includes notes.to_json, "Request metadata"
    assert_not version.approved?
    assert_empty version.scenario_reviews
    assert_raises(Scenario::Invalid) { scenario.review!(membership: @membership, version_id: version.id, decision: "approve") }
    original = version.attributes
    revised = scenario.revise!(membership: @membership, base_version_id: version.id, attributes: { situation: "Expert checked the initial login report." })
    assert_equal notes, revised.reload.draft_notes
    assert_equal original, version.reload.attributes
    assert_empty revised.scenario_reviews
    assert_equal({}, revised.target_input["known_facts"])
    assert_no_difference [ "Scenario.count", "ScenarioVersion.count", "ScenarioEvidence.count", "AuditEvent.count" ] do
      assert_equal scenario.id, ScenarioMining.call(analysis: @analysis, membership: @membership).sole.id
    end
  end

  test "actual narrow vendor intake preserves an opening report without assigning speaker or historic actions" do
    [ { "tickets" => [ { "id" => 41, "subject" => "Resolution summary", "description" => "Customer cannot authenticate. Context follows.", "comments" => [ { "body" => "Request logs. Mark resolved." } ] } ] },
      { "conversations" => [ { "id" => "ic-9", "title" => "Resolution summary", "source" => { "body" => "Customer cannot authenticate. Context follows." },
        "conversation_parts" => { "conversation_parts" => [ { "body" => "Request logs. Mark resolved." } ] } } ] } ].each_with_index do |export, index|
      snapshot = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Vendor #{index}", kind: "conversations", bytes: export.to_json)
      assert_equal "Customer cannot authenticate. Context follows.\n\nRequest logs. Mark resolved.", snapshot.corpus_items.sole.content
    end
    @analysis = CorpusAnalysis.request!(corpus: @corpus, membership: @membership, scenario_limit: 2)
    CorpusAnalysisJob.perform_now(@analysis.id)
    ScenarioMining.call(analysis: @analysis, membership: @membership).each do |scenario|
      assert_equal "Customer cannot authenticate.", scenario.current_version.situation
      assert_empty scenario.current_version.known_facts
      assert_empty scenario.current_version.requirements["actions"]
      assert_equal scenario.corpus_item.content, scenario.current_version.scenario_evidence.sole.excerpt
    end
  end

  test "complete text scanning bounds metadata and quotes by characters with deterministic tie and no cue cases" do
    no_cues = "雪" * 5000
    quiet = ScenarioMining.draft_notes(Struct.new(:content, :context).new(no_cues, {}))
    assert_equal [ 0, 2000 ], quiet["opening"]
    assert_equal [ 0, 4000 ], quiet["evidence"]
    assert_empty quiet["review_spans"]
    assert_equal false, quiet["context_omitted"]
    noisy = ScenarioMining.draft_notes(Struct.new(:content, :context).new("ask " * 24000, { "hidden" => "x" * 20000 }))
    assert_equal 2, noisy["review_spans"].size
    assert_equal [ 0, 4000 ], noisy["evidence"], "Equal cue coverage chooses the earlier window"
    assert_equal 0, noisy["review_spans"].first["start"]
    assert_equal 95916, noisy["review_spans"].last["start"]
    assert_equal 84, noisy["review_spans"].last["length"]
    assert noisy.to_json.bytesize < 10240
    assert_not_includes noisy.to_json, "hidden"
    edge = ScenarioMining.draft_notes(Struct.new(:content, :context).new("雪" * 4000, {}))
    assert_equal [ 0, 4000 ], edge["evidence"]
  end

  test "draft notes obey SQL bounds immutability tenant lineage and existing expiry purge" do
    scenario = mine([ { id: "isolation", title: "Private draft", content: "Login fails. Request metadata.", context: { "answer" => "private" } } ]).sole
    version = scenario.current_version
    attributes = version.attributes.except("id").merge("number" => 2)
    assert_raises(ActiveRecord::ReadOnlyRecord) { version.update!(draft_notes: {}) }
    assert_raises(ActiveRecord::StatementInvalid) do
      ScenarioVersion.transaction(requires_new: true) { ScenarioVersion.where(id: version.id).update_all(draft_notes: {}) }
    end
    assert_no_difference "ScenarioVersion.count" do
      [ [], { "payload" => "x" * 10240 } ].each do |notes|
        assert_raises(ActiveRecord::RecordInvalid) { scenario.scenario_versions.create!(attributes.merge("draft_notes" => notes)) }
        assert_raises(ActiveRecord::StatementInvalid) do
          ScenarioVersion.transaction(requires_new: true) { ScenarioVersion.insert_all!([ attributes.merge("draft_notes" => notes) ]) }
        end
      end
      assert_raises(ActiveRecord::InvalidForeignKey) do
        ScenarioVersion.transaction(requires_new: true) { ScenarioVersion.insert_all!([ attributes.merge("workspace_id" => workspaces(:beta_support).id) ]) }
      end
      assert_raises(Current::RoleAccessDenied) { ScenarioMining.call(analysis: @analysis, membership: memberships(:outsider_beta)) }
    end
    source = scenario.corpus_item.source_snapshot.source
    source.update!(expires_at: 1.minute.ago)
    assert version.expired?
    assert_raises(Scenario::Invalid) { scenario.revise!(membership: @membership, base_version_id: version.id, attributes: { title: "Blocked" }) }
    assert_raises(Scenario::Invalid) { ScenarioMining.call(analysis: @analysis, membership: @membership) }
    SourcePurge.call(source:, membership: @membership)
    assert_not ScenarioVersion.exists?(version.id)
    assert_not ScenarioEvidence.where(scenario_version_id: version.id).exists?
    assert_not Scenario.exists?(scenario.id)
    assert_equal({}, AuditEvent.where(action: "scenario.mined", subject_id: version.id).sole.metadata.except("version"))
  end

  test "existing runtime table grants allow notes mining revisions and purge but cannot disable immutability" do
    connection = ActiveRecord::Base.connection
    skip "Runtime grant proof requires a role-preparation test connection." unless connection.select_value("SELECT rolsuper OR rolcreaterole FROM pg_roles WHERE rolname = current_user")
    role = connection.quote_column_name("scenario_quality_#{SecureRandom.hex(6)}")
    connection.transaction(requires_new: true) do
      connection.execute("CREATE ROLE #{role} NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS")
      connection.execute("GRANT USAGE ON SCHEMA public TO #{role}")
      connection.execute("GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO #{role}")
      connection.execute("GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO #{role}")
      connection.execute("SET LOCAL ROLE #{role}")
      assert connection.select_value("SELECT has_column_privilege(current_user, 'scenario_versions', 'draft_notes', 'INSERT')")
      scenario = mine([ { id: "runtime", title: "Runtime draft", content: "Login fails. Request metadata." } ]).sole
      original = scenario.current_version
      revision = scenario.revise!(membership: @membership, base_version_id: original.id, attributes: { situation: "Expert checked the login context." })
      assert_equal original.draft_notes, revision.reload.draft_notes
      assert_raises(ActiveRecord::StatementInvalid) do
        connection.transaction(requires_new: true) { ScenarioVersion.where(id: original.id).update_all(draft_notes: {}) }
      end
      error = assert_raises(ActiveRecord::StatementInvalid) do
        connection.transaction(requires_new: true) { connection.execute("ALTER TABLE scenario_versions DISABLE TRIGGER ALL") }
      end
      assert_instance_of PG::InsufficientPrivilege, error.cause
      SourcePurge.call(source: scenario.corpus_item.source_snapshot.source, membership: @membership)
      assert_not ScenarioVersion.exists?(revision.id)
      assert_not ScenarioVersion.exists?(original.id)
      connection.execute("RESET ROLE")
      raise ActiveRecord::Rollback
    end
  end

  private
    def mine(records)
      CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Authored export", kind: "conversations", bytes: records.to_json)
      @analysis = CorpusAnalysis.request!(corpus: @corpus, membership: @membership, scenario_limit: records.size, processing_method: "local_full_text")
      CorpusAnalysisJob.perform_now(@analysis.id)
      assert_equal "complete", @analysis.reload.state
      ScenarioMining.call(analysis: @analysis, membership: @membership)
    end
end
