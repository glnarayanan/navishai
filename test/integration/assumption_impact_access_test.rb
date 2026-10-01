require "test_helper"
require_relative "../test_helpers/assumption_impact_test_helper"

class AssumptionImpactAccessTest < ActionDispatch::IntegrationTest
  include AssumptionImpactTestHelper
  setup do
    build_change_impact
    sign_in_as users(:owner)
  end

  test "local preview shows complete documents and fixed assumptions but queues nothing" do
    assert_no_difference([ "AssumptionImpact.count", "AuditEvent.count" ]) do
      get new_workspace_corpus_assumption_impact_path(@workspace, @corpus), params: impact_selection_params
      assert_response :success
      assert_select "#impact-preview", text: /Only Enterprise plans support SAML/
      assert_select "#impact-preview", text: /Business and Enterprise plans support SAML/
      assert_select "#impact-preview", text: /Business excludes SAML/
      assert_select "#impact-request input[name=version_ids][value='#{@version_ids.join(' ')}']"
      assert_select "#impact-request input#impact_disclose", count: 0
      assert_select "#impact-request input[type=submit]", count: 0
      ids = css_select("[id]").map { |node| node["id"] }
      assert_equal ids.uniq, ids, "Visible labels must not share IDs with hidden confirmation inputs"
      assert_select "a[href=?]", workspace_corpus_source_path(@workspace, @corpus, @source, snapshot: @before.number, anchor: "record-#{@before.corpus_items.sole.id}"), text: "Inspect before source snapshot"
    end
  end

  test "exact wire preview sends nothing and matches actual transport bytes without local provenance" do
    with_old_purpose_approvals do
      assert_no_enqueued_jobs do
        assert_no_difference([ "AssumptionImpact.count", "AuditEvent.count" ]) do
          post workspace_corpus_assumption_impacts_path(@workspace, @corpus), params: impact_request_params.except(:impact_disclose, :wire_digest).merge(preview_only: "1")
          assert_response :success
        end
      end
      wire = css_select("#impact-wire pre").sole.text
      assert_equal %w[content context title], JSON.parse(wire).fetch("input").fetch("before").keys.sort
      assert_select "#impact-request input#impact_disclose[checked]", count: 0
      assert_select "#impact-request input[name=wire_digest][value=?]", AssumptionChangeAnalysis.wire_digest(impact_preview, impact_configuration)
      with_impact_response(calls: calls = []) do
        post workspace_corpus_assumption_impacts_path(@workspace, @corpus), params: impact_request_params
        assert_response :see_other
        impact = AssumptionImpact.where(corpus: @corpus).sole
        AssumptionImpactJob.perform_now(impact.id)
        assert_equal 1, calls.size
        assert_equal wire, calls.sole.body
        get workspace_corpus_assumption_impact_path(@workspace, @corpus, impact)
        assert_response :success
        assert_equal wire, css_select("#impact-wire pre").sole.text, "JSONB ordering cannot change the fixed wire"
      end
    end
  end

  test "missing consent invalid configuration changed previews repair with fresh unchecked confirmation" do
    with_impact_approval do
      assert_no_difference([ "AssumptionImpact.count", "AuditEvent.count" ]) do
        post workspace_corpus_assumption_impacts_path(@workspace, @corpus), params: impact_request_params.except(:impact_disclose)
        assert_response :unprocessable_content
        assert_select "[role=alert]", text: /Confirm disclosure/
        assert_select "textarea#configuration", text: impact_configuration.to_json
        assert_select "input#impact_disclose[checked]", count: 0
        post workspace_corpus_assumption_impacts_path(@workspace, @corpus), params: impact_request_params.merge(configuration: "{broken")
        assert_response :unprocessable_content
        assert_select "[role=alert]", text: /valid JSON/
        assert_select "textarea#configuration", text: "{broken"
        post workspace_corpus_assumption_impacts_path(@workspace, @corpus), params: impact_request_params.merge(input_digest: "0" * 64)
        assert_response :unprocessable_content
        assert_select "[role=alert]", text: /preview changed/
        assert_select "input#impact_disclose[checked]", count: 0
        [ impact_request_params.except(:wire_digest),
          impact_request_params.merge(configuration: impact_configuration.deep_merge("settings" => { "seed" => 99 }).to_json) ].each do |request|
          post workspace_corpus_assumption_impacts_path(@workspace, @corpus), params: request
          assert_response :unprocessable_content
          assert_select "[role=alert]", text: /exact model request changed/
          assert_select "input#impact_disclose[checked]", count: 0
        end
      end
      post workspace_corpus_assumption_impacts_path(@workspace, @corpus), params: impact_request_params
      assert_response :see_other
      assert_difference("AssumptionImpact.count", 0) { post workspace_corpus_assumption_impacts_path(@workspace, @corpus), params: impact_request_params }
      follow_redirect!
      assert_select "[role=status]", text: /Queued/
      assert_select "a", text: "Refresh attempt state"
      assert_select "form button[type=submit]", text: "Interrupt change analysis", count: 1
    end
  end

  test "viewers inspect escaped fixed receipts with no request or interrupt and foreign tenants see no data" do
    with_impact_response(response: impact_response.merge("reason" => "<script>untrusted proposal</script>")) do
      @impact = request_impact
      AssumptionImpactJob.perform_now(@impact.id)
    end
    Membership.create!(workspace: @workspace, user: users(:teammate), role: :viewer)
    sign_in_as users(:teammate)
    assert_no_difference([ "AssumptionImpact.count", "ScenarioVersion.count", "ScenarioReview.count", "AuditEvent.count" ]) do
      get workspace_corpus_assumption_impact_path(@workspace, @corpus, @impact)
      assert_response :success
      assert_select "#impact-result", text: /Uncertainty/
      assert_select "script", text: /untrusted proposal/, count: 0
      assert_select "a", text: "Inspect current scenario"
      assert_select "a", text: "Open current version for separate revision and review", count: 0
      assert_select "input[type=submit]", count: 0
      get new_workspace_corpus_assumption_impact_path(@workspace, @corpus)
      assert_response :forbidden
      post workspace_corpus_assumption_impacts_path(@workspace, @corpus), params: impact_request_params
      assert_response :forbidden
      post interrupt_workspace_corpus_assumption_impact_path(@workspace, @corpus, @impact)
      assert_response :forbidden
      get workspace_corpus_assumption_impact_path(workspaces(:beta_support), @corpus, @impact)
      assert_response :not_found
    end
  end

  test "expiry hides private receipt history and interrupts unsent work" do
    with_impact_approval { @impact = request_impact }
    @source.update!(expires_at: 1.minute.ago)
    get workspace_corpus_assumption_impact_path(@workspace, @corpus, @impact)
    assert_response :not_found
    get workspace_corpus_assumption_impacts_path(@workspace, @corpus)
    assert_response :success
    assert_select "[role=status]", text: /expired/
    assert_select "a", text: /Attempt #/, count: 0
    get new_workspace_corpus_assumption_impact_path(@workspace, @corpus), params: impact_selection_params
    assert_response :success
    assert_select "#impact-preview", count: 0
    assert_select "#impact-request", count: 0
    with_impact_response(calls: calls = []) { AssumptionImpactJob.perform_now(@impact.id) }
    assert_empty calls
    assert_equal "interrupted", @impact.reload.state
  end

  test "legacy v1 consent never dispatches under the v2 disclosure contract" do
    with_impact_response(calls: calls = []) do
      original = request_impact
      attributes = original.attributes.except("id").merge("processing_version" => "source-assumption-impact-v1",
        "request_key" => SecureRandom.uuid, "request_digest" => "b" * 64)
      legacy = AssumptionImpact.find(AssumptionImpact.insert_all!([ attributes ], returning: %w[id]).rows.sole.sole)
      original.assumption_impact_inputs.each do |entry|
        legacy.assumption_impact_inputs.create!(workspace: @workspace, corpus: @corpus, scenario_version_id: entry.scenario_version_id)
      end
      2.times { AssumptionImpactJob.perform_now(legacy.id) }
      assert_empty calls
      assert_equal "interrupted", legacy.reload.state
      assert_nil legacy.assumption_impact_result
      get workspace_corpus_assumption_impact_path(@workspace, @corpus, legacy)
      assert_response :success
      assert_select "[role=status]", text: /queued legacy attempts cannot dispatch/
      assert_select "#impact-wire", count: 0
    end
  end

  test "completed historical proposals remain inspectable after newer versions without applying old assumptions" do
    with_impact_response do
      @impact = request_impact
      AssumptionImpactJob.perform_now(@impact.id)
    end
    @scenario.revise!(membership: @membership, base_version_id: @version.id, attributes: { title: "Expert revision after result" })
    import_impact_document("Another product change after result.")
    get workspace_corpus_assumption_impact_path(@workspace, @corpus, @impact)
    assert_response :success
    assert_select "[role=status]", text: /document head changed/
    assert_select "[role=status]", text: /scenario has a newer version/
    assert_select "a[href=?]", workspace_corpus_scenario_path(@workspace, @corpus, @scenario), text: "Open current version for separate revision and review"
    assert_select "a[href=?]", workspace_corpus_scenario_path(@workspace, @corpus, @scenario, version: @version.number), text: "Inspect proposed fixed version"
    assert_equal @version.id, @impact.input.fetch("scenarios").find { |entry| entry.fetch("scenario_id") == @scenario.id }.fetch("version_id")
  end

  test "whole source and snapshot IDs reject partial casting; foreign snapshots and versions do not disclose" do
    [ "#{@source.id}.0", "#{@source.id}e0", [ @source.id ] ].each do |value|
      get new_workspace_corpus_assumption_impact_path(@workspace, @corpus), params: impact_selection_params.merge(source_id: value)
      assert_response :success
      assert_select "[role=alert]", text: /whole IDs/
      assert_select "#impact-preview", count: 0
    end
    get new_workspace_corpus_assumption_impact_path(@workspace, @corpus), params: impact_selection_params.merge(after_snapshot_id: @knowledge.source_snapshot_id)
    assert_response :not_found
    get new_workspace_corpus_assumption_impact_path(@workspace, @corpus), params: impact_selection_params.merge(scenario_ids: "#{2**63 - 1}")
    assert_response :not_found
  end
end
