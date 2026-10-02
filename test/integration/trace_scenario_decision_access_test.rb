require "test_helper"
require_relative "../support/failure_matching_fixture"

class TraceScenarioDecisionAccessTest < ActionDispatch::IntegrationTest
  include FailureMatchingFixture
  setup do
    build_failure_matching_fixture
    sign_in_as users(:owner)
  end

  test "GET is read only POST retains errors and history and lifetime hides associations" do
    assert_no_difference [ "TraceScenarioDecision.count", "ScenarioVersion.count", "AuditEvent.count" ] do
      assert_no_enqueued_jobs do
        get source_path
        assert_response :success
        assert_select "p", text: /Exact shared terms:.*certificate/
        assert_select "h6", text: "Conflicting known facts — review caution"
      end
    end
    assert_no_difference "TraceScenarioDecision.count" do
      post decision_path, params: values.merge(decision: "invalid", reason: "Retain this explanation")
      assert_response :unprocessable_entity
      assert_select "textarea", text: "Retain this explanation"
    end
    post decision_path, params: values
    assert_response :see_other
    follow_redirect!
    assert_select "p", text: /Latest for this expert and version/
    assert_not @version.approved?
    @document.source_snapshot.source.update!(expires_at: 1.minute.ago)
    get source_path
    assert_response :success
    assert_select "p", text: /Matches hidden/
    assert_select "p", text: /Latest for this expert/, count: 0
    assert_no_difference "TraceScenarioDecision.count" do
      post decision_path, params: values
      assert_response :unprocessable_entity
    end
  end

  test "second history page never presents an old label as an expert's latest decision" do
    51.times { |index| append_decision(reason: "Association history #{index}") }
    get source_path, params: { snapshot: @item.source_snapshot.number, page: 1, decision_page: 2 }
    assert_response :success
    assert_select "p", text: "Association history 0"
    assert_select "p", text: "Association history 50", count: 0
    assert_select "p", text: /Earlier decision/, count: 1
    assert_select "p", text: /Latest for this expert and version/, count: 0
    assert_select "a[href*='decision_page=1'][href*='snapshot=1']", text: "Previous decisions"
  end

  test "viewers foreign corpora and stale forms cannot save" do
    foreign = @corpus.workspace.corpora.create!(name: "Foreign")
    assert_no_difference "TraceScenarioDecision.count" do
      post decide_trace_workspace_corpus_source_path(@corpus.workspace, foreign, @item.source_snapshot.source), params: values
      assert_response :not_found
      post decide_trace_workspace_corpus_source_path(workspaces(:beta_support), @corpus, @item.source_snapshot.source), params: values
      assert_response :not_found
      @version.scenario.revise!(membership: @membership, base_version_id: @version.id, attributes: { title: "Updated certificate" })
      post decision_path, params: values
      assert_response :unprocessable_entity
      assert_select "summary", text: "Retained decision on unavailable version"
    end
    Membership.create!(workspace: @corpus.workspace, user: users(:teammate), role: :viewer)
    sign_in_as users(:teammate)
    get source_path
    assert_response :success
    assert_select "input[type=submit][value='Append trace decision']", count: 0
    assert_no_difference "TraceScenarioDecision.count" do
      post decision_path, params: values
      assert_response :forbidden
    end
  end

  test "experts can select an eligible scenario outside literal suggestions without granting approval" do
    missed = matching_version(title: "Invoice approval", situation: "Ledger reconciliation needs a finance contact.", facts: {}, excerpt: "Invoices require a billing contact.")
    assert_not_includes TraceScenarioMatching.call(item: @item).candidates.map { |entry| entry.version.id }, missed.id
    selection = { selected_trace_id: @item.id, selected_scenario_id: missed.scenario_id }
    assert_no_difference [ "TraceScenarioDecision.count", "ScenarioVersion.count", "AuditEvent.count" ] do
      assert_no_enqueued_jobs do
        get source_path, params: selection
        assert_response :success
        assert_select "#selected-scenario-#{@item.id} h5", text: "Expert-selected scenario"
        assert_select "#selected-scenario-#{@item.id} a[href*='trace_item_id=#{@item.id}']", text: "Revise selected scenario with this trace"
        assert_select "#selected-scenario-#{@item.id} input[name=scenario_version_id][value='#{missed.id}']"
      end
    end
    selected_values = values.merge(scenario_version_id: missed.id, selected_scenario_id: missed.scenario_id)
    post decision_path, params: selected_values.merge(decision: "invalid", reason: "Retain the expert's comparison")
    assert_response :unprocessable_entity
    assert_select "#selected-scenario-#{@item.id} textarea", text: "Retain the expert's comparison"
    assert_select "#selected-scenario-#{@item.id} input[name=scenario_version_id][value='#{missed.id}']"
    assert_no_difference [ "ScenarioVersion.count", "ScenarioReview.count", "EvalCase.count" ] do
      assert_difference "TraceScenarioDecision.count", 1 do
        post decision_path, params: selected_values
        assert_response :see_other
      end
    end
    assert_equal missed.id, TraceScenarioDecision.order(:id).last.scenario_version_id
    assert_not missed.reload.approved?

    missed.scenario.revise!(membership: @membership, base_version_id: missed.id, attributes: { title: "Updated invoice approval" })
    assert_no_difference "TraceScenarioDecision.count" do
      post decision_path, params: selected_values
      assert_response :unprocessable_entity
      assert_select "#selected-scenario-#{@item.id} input[name=scenario_version_id]", count: 0
      assert_select "summary", text: "Retained decision on unavailable version"
      assert_select "pre", text: selected_values[:reason]
    end
  end

  test "manual selection remains available after top five displacement and refuses foreign or rejected choices" do
    6.times do |index|
      matching_version(title: "SSO stopped after a customer changed the certificate configuration evidence #{index}",
        situation: "The agent claimed a configuration change without collecting certificate evidence.")
    end
    assert_not_includes TraceScenarioMatching.call(item: @item).candidates.map { |entry| entry.version.id }, @version.id
    selection = { selected_trace_id: @item.id, selected_scenario_id: @version.scenario_id }
    get source_path, params: selection
    assert_response :success
    assert_select "#selected-scenario-#{@item.id} input[name=scenario_version_id][value='#{@version.id}']"

    foreign = @corpus.workspace.corpora.create!(name: "Other corpus")
    document = CorpusIntake.call(corpus: foreign, membership: @membership, name: "Private policy", kind: "document", bytes: "Private expectation.").corpus_items.sole
    version = matching_version(title: "Do not disclose this title", corpus: foreign, item: document, excerpt: document.content)
    get source_path, params: selection.merge(selected_scenario_id: version.scenario_id)
    assert_response :success
    assert_select "#selected-scenario-#{@item.id} p[role=status]", text: /Choose a scenario in this corpus/
    assert_select "a", text: /Do not disclose this title/, count: 0
    assert_select "#selected-scenario-#{@item.id} input[name=scenario_version_id]", count: 0
    get source_path, params: selection.merge(selected_trace_id: document.id)
    assert_response :not_found

    @version.scenario.review!(membership: @membership, version_id: @version.id, decision: "reject")
    get source_path, params: selection
    assert_response :success
    assert_select "#selected-scenario-#{@item.id} p[role=status]", text: /not eligible for an association/
    assert_select "#selected-scenario-#{@item.id} input[name=scenario_version_id]", count: 0
    assert_empty TraceScenarioDecision.where(corpus: @corpus)
  end

  test "manual lookup never aliases decimal exponent suffix or collection input to another scenario ID" do
    id = @version.scenario_id.to_s
    invalid_ids = [ "#{id}.5", "#{id}e2", "#{id}suffix", [ id ], { value: id }, "9" * 20 ]
    assert_no_difference [ "TraceScenarioDecision.count", "ScenarioVersion.count", "ScenarioReview.count", "AuditEvent.count" ] do
      assert_no_enqueued_jobs do
        invalid_ids.each do |invalid_id|
          get source_path, params: { selected_trace_id: @item.id, selected_scenario_id: invalid_id }
          assert_response :success
          assert_select "#selected-scenario-#{@item.id} p[role=status]", text: /Choose a scenario in this corpus/
          assert_select "#selected-scenario-#{@item.id} input[name=scenario_version_id]", count: 0
          assert_select "#selected-scenario-#{@item.id} a[href*='trace_item_id']", count: 0
        end
        get source_path, params: { selected_trace_id: @item.id, selected_scenario_id: id }
        assert_response :success
        assert_select "#selected-scenario-#{@item.id} input[name=scenario_version_id][value='#{@version.id}']"
      end
    end
  end

  test "viewers can inspect an explicit selection but neither decide nor revise it" do
    Membership.create!(workspace: @corpus.workspace, user: users(:teammate), role: :viewer)
    sign_in_as users(:teammate)
    assert_no_difference [ "TraceScenarioDecision.count", "ScenarioVersion.count", "AuditEvent.count" ] do
      get source_path, params: { selected_trace_id: @item.id, selected_scenario_id: @version.scenario_id }
      assert_response :success
      assert_select "#selected-scenario-#{@item.id} h5", text: "Expert-selected scenario"
      assert_select "#selected-scenario-#{@item.id} input[name=scenario_version_id]", count: 0
      assert_select "a", text: "Revise selected scenario with this trace", count: 0
    end
  end

  private
    def source_path
      workspace_corpus_source_path(@corpus.workspace, @corpus, @item.source_snapshot.source)
    end

    def decision_path
      decide_trace_workspace_corpus_source_path(@corpus.workspace, @corpus, @item.source_snapshot.source)
    end

    def values
      { corpus_item_id: @item.id, scenario_version_id: @version.id, decision: "match", reason: "Certificate evidence overlaps, entitlement differs." }
    end
end
