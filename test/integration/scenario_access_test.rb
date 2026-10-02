require "test_helper"
require_relative "../test_helpers/scenario_test_helper"

class ScenarioAccessTest < ActionDispatch::IntegrationTest
  include ScenarioTestHelper

  setup do
    build_scenarios
    sign_in_as users(:owner)
  end

  test "read write errors preserve expert input and foreign routes are hidden" do
    get workspace_corpus_scenario_path(@workspace, @corpus, @scenario)
    assert_response :success
    assert_select "h2", text: "Company evidence"
    patch workspace_corpus_scenario_path(@workspace, @corpus, @scenario), params: { version_id: @scenario.current_version_id, scenario: { title: "Keep my edits", known_facts: "broken JSON", hidden_facts: "{}" } }
    assert_response :unprocessable_content
    assert_select "input[name='scenario[title]'][value='Keep my edits']"
    assert_select "textarea[name='scenario[known_facts]']", text: "broken JSON"
    assert_select "[role=alert]", text: /valid JSON/
    get workspace_corpus_scenario_path(workspaces(:beta_support), @corpus, @scenario)
    assert_response :not_found
    get workspace_corpus_scenario_path(@workspace, @corpus, @scenario, version: 99)
    assert_response :not_found
  end

  test "trace entry selects exact evidence without copying input corrections or creating records" do
    trace = JSON.parse(File.read(Rails.root.join("test/fixtures/files/production_traces.json"))).sole
    trace["input"]["known_facts"]["plan"] = "starter"
    item = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "New production failure", kind: "traces", bytes: [ trace ].to_json).corpus_items.sole
    original = @scenario.current_version
    assert_no_difference [ "ScenarioVersion.count", "ScenarioReview.count", "AuditEvent.count", "HumanLabel.count", "ScenarioProposal.count" ] do
      get workspace_corpus_scenario_path(@workspace, @corpus, @scenario, trace_item_id: item.id, anchor: "scenario-evidence")
      assert_response :success
      assert_select "details#scenario-evidence[open]"
      assert_select "select[name=evidence_item_id] option[selected][value='#{item.id}']"
      assert_select "input[name=trace_item_id][value='#{item.id}']"
      assert_select "textarea[name=excerpt]", text: ""
      assert_select "textarea[name='scenario[situation]']", text: original.situation
      assert_select "textarea[name='scenario[known_facts]']" do |fields|
        assert_equal original.known_facts, JSON.parse(fields.sole.text)
      end
      assert_select "textarea[name='scenario[outcomes]']", text: ""
    end
    patch workspace_corpus_scenario_path(@workspace, @corpus, @scenario), params: { trace_item_id: item.id,
      version_id: original.id, evidence_item_id: item.id, evidence_kind: "expectation", excerpt: "Keep my invalid excerpt",
      scenario: { title: "Keep the expert edit", known_facts: "broken", hidden_facts: "{}" } }
    assert_response :unprocessable_content
    assert_select "details#scenario-evidence[open]"
    assert_select "select[name=evidence_item_id] option[selected][value='#{item.id}']"
    assert_select "textarea[name=excerpt]", text: "Keep my invalid excerpt"
    assert_select "input[name='scenario[title]'][value='Keep the expert edit']"
    assert_equal original.id, @scenario.reload.current_version_id
    assert_no_difference "ScenarioVersion.count" do
      patch workspace_corpus_scenario_path(@workspace, @corpus, @scenario), params: { trace_item_id: item.id,
        version_id: original.id, evidence_item_id: item.id, evidence_kind: "expectation", excerpt: "Keep my invalid excerpt",
        scenario: { known_facts: original.known_facts.to_json, hidden_facts: "{}" } }
      assert_response :unprocessable_content
      assert_select "#evidence-error[role=alert]", text: /Read the exact source record, paste a matching excerpt and save again/
      assert_select "textarea[name=excerpt][aria-invalid=true][aria-describedby=evidence-error]", text: "Keep my invalid excerpt"
    end
  end

  test "trace entry rejects foreign corpus expired wrong-kind and non-scalar references" do
    trace = JSON.parse(File.read(Rails.root.join("test/fixtures/files/production_traces.json"))).sole
    foreign_corpus = @workspace.corpora.create!(name: "Other isolated dataset")
    foreign = CorpusIntake.call(corpus: foreign_corpus, membership: @membership, name: "Other failure", kind: "traces", bytes: [ trace ].to_json).corpus_items.sole
    get workspace_corpus_scenario_path(@workspace, @corpus, @scenario, trace_item_id: foreign.id)
    assert_response :not_found
    get workspace_corpus_scenario_path(@workspace, @corpus, @scenario, trace_item_id: @knowledge.id)
    assert_response :not_found
    get workspace_corpus_scenario_path(@workspace, @corpus, @scenario, trace_item_id: [ @knowledge.id ])
    assert_response :bad_request
    item = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Expired failure", kind: "traces", bytes: [ trace ].to_json).corpus_items.sole
    item.source_snapshot.source.update!(expires_at: 1.minute.ago)
    get workspace_corpus_scenario_path(@workspace, @corpus, @scenario, trace_item_id: item.id)
    assert_response :not_found
  end

  test "viewer cannot revise review mine or create variants and expiry hides index titles" do
    Membership.create!(workspace: @workspace, user: users(:teammate), role: :viewer)
    sign_in_as users(:teammate)
    get workspace_corpus_scenario_path(@workspace, @corpus, @scenario)
    assert_response :success
    assert_select "input[type=submit]", count: 0
    patch workspace_corpus_scenario_path(@workspace, @corpus, @scenario), params: {}
    assert_response :forbidden
    post review_workspace_corpus_scenario_path(@workspace, @corpus, @scenario), params: {}
    assert_response :forbidden
    post variant_workspace_corpus_scenario_path(@workspace, @corpus, @scenario), params: {}
    assert_response :forbidden
    post workspace_corpus_scenarios_path(@workspace, @corpus), params: { analysis_id: @analysis.id }
    assert_response :forbidden
    travel 366.days do
      sign_in_as users(:teammate)
      get workspace_corpus_scenarios_path(@workspace, @corpus)
      assert_response :success
      assert_select ".workspace-card", count: 0
      get workspace_corpus_scenario_path(@workspace, @corpus, @scenario)
      assert_response :not_found
    end
  end

  test "malformed follow up shape retains the expert JSON and repair details" do
    plan = '[{"after_assistant_contains":"expiry","message":"date","unexpected":true}]'
    patch workspace_corpus_scenario_path(@workspace, @corpus, @scenario), params: { version_id: @scenario.current_version_id,
      scenario: { known_facts: "{}", hidden_facts: "{}", follow_ups: plan } }
    assert_response :unprocessable_content
    assert_select "textarea[name='scenario[follow_ups]']", text: plan
    assert_select "[role=alert]", text: /Follow ups.*exactly after_assistant_contains/
  end

  test "an omitted plan preserves existing follow-ups while an explicit empty array removes them" do
    plan = [ { "after_assistant_contains" => "expiry", "message" => "It expired yesterday." } ]
    version = @scenario.revise!(membership: @membership, base_version_id: @scenario.current_version_id, attributes: { follow_ups: plan })
    values = { title: "Changed starting title", known_facts: version.known_facts.to_json, hidden_facts: version.hidden_facts.to_json }
      .merge(version.requirements.transform_values { |statements| statements.join("\n") })
    patch workspace_corpus_scenario_path(@workspace, @corpus, @scenario), params: { version_id: version.id, scenario: values }
    assert_response :see_other
    assert_equal plan, @scenario.reload.current_version.follow_ups
    assert_equal plan, version.reload.follow_ups
    patch workspace_corpus_scenario_path(@workspace, @corpus, @scenario), params: { version_id: @scenario.current_version_id, scenario: values.merge(follow_ups: "[]") }
    assert_response :see_other
    assert_empty @scenario.reload.current_version.follow_ups
    assert_equal plan, version.reload.follow_ups
  end
end
