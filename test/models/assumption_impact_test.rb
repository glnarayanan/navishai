require "test_helper"
require_relative "../test_helpers/assumption_impact_test_helper"

class AssumptionImpactTest < ActiveSupport::TestCase
  include AssumptionImpactTestHelper
  setup { build_change_impact }

  test "unlinked assumptions are fixed and quoted without authority or exact-dependency changes" do
    assert_empty @source.dependent_versions
    evidence = @version.scenario_evidence.pluck(:corpus_item_id, :kind, :excerpt)
    original = @version.attributes
    input = impact_preview
    assert_equal @before.digest, input.dig("before", "digest")
    assert_equal @after.created_at.iso8601(6), input.dig("after", "intake_time")
    assert_equal @before.mask_digest, input.dig("before", "mask_digest")
    assert_equal @after.corpus_items.sole.content, input.dig("after", "content")
    assert_equal @version_ids, input.fetch("scenarios").pluck("version_id")
    assert_equal [ "Business excludes SAML" ], input.fetch("scenarios").find { |entry| entry["version_id"] == @version.id }.fetch("assumptions").fetch("hidden_facts").values
    calls = []
    with_impact_response(calls:) do
      assert_no_difference([ "ScenarioVersion.count", "ScenarioReview.count", "HumanLabel.count", "EvalCase.count" ]) do
        impact = request_impact
        assert_equal impact.id, request_impact.id
        2.times { AssumptionImpactJob.perform_now(impact.id) }
        assert_equal "complete", impact.reload.state
        assert_equal [ impact_response["affected"].sole ], impact.assumption_impact_result.result.fetch("affected")
        assert_equal input, impact.input
        assert_equal @version_ids, impact.assumption_impact_inputs.order(:scenario_version_id).pluck(:scenario_version_id)
        assert_equal 1, calls.size
        assert_equal impact.request_key, calls.sole["Idempotency-Key"]
        body = JSON.parse(calls.sole.body)
        assert_equal input, body.fetch("input")
        assert_equal "source-assumption-impact-v1", body.fetch("schema")
        assert_equal 20, body.fetch("proposal_limit")
        assert_not_includes calls.sole.body, "Synthetic expert fixture only"
        assert_not_includes calls.sole.body, "test-only-impact-token"
        assert_nil impact.assumption_impact_result.result["cost"]
      end
    end
    assert_empty @source.dependent_versions
    assert_equal original, @version.reload.attributes
    assert_equal evidence, @version.scenario_evidence.pluck(:corpus_item_id, :kind, :excerpt)
    assert @version.approved?
    assert_not @version.stale?
  end

  test "exact corpus purpose and human digest-bound consent are required before queueing" do
    with_impact_approval do
      assert_no_difference([ "AssumptionImpact.count", "AuditEvent.count" ]) do
        assert_raises(CorpusIntake::Invalid) { request_impact(disclose: false) }
        assert_raises(CorpusIntake::Invalid) { request_impact(input_digest: "0" * 64) }
        assert_raises(CorpusIntake::Invalid) { request_impact(configuration: impact_configuration.merge("secret" => "not-allowed")) }
      end
    end
    with_impact_approval(workspace_id: workspaces(:beta_support).id) { assert_raises(EvaluationHttp::Error) { request_impact } }
    with_impact_approval(endpoint: "https://example.com/different") { assert_raises(EvaluationHttp::Error) { request_impact } }
    with_impact_approval do
      ENV["NAVISHAI_CORPUS_ENDPOINTS"] = "[]"
      with_endpoint_approval { assert_raises(EvaluationHttp::Error) { request_impact } }
    end
    assert_equal 0, AssumptionImpact.where(corpus: @corpus).count
  end

  test "historical after snapshots need separate confirmation and remain exact" do
    latest = import_impact_document("All plans now support SAML; historic entitlement is not current policy.")
    input = impact_preview
    assert input.fetch("historical")
    assert_equal latest.id, input.fetch("source_head_id")
    with_impact_response do
      assert_raises(CorpusIntake::Invalid) { request_impact }
      impact = request_impact(historical: true)
      AssumptionImpactJob.perform_now(impact.id)
      assert_equal "complete", impact.reload.state
      assert_equal @after.id, impact.after_snapshot_id
      assert_equal @after.corpus_items.sole.content, impact.input.dig("after", "content")
      assert_not_includes impact.input.to_json, "All plans now support SAML"
    end
  end

  test "snapshot order source scope and foreign corpus versions cannot enter previews" do
    assert_raises(CorpusIntake::Invalid) { impact_preview(before_snapshot_id: @after.id) }
    assert_raises(CorpusIntake::Invalid) { impact_preview(before_snapshot_id: @after.id, after_snapshot_id: @before.id) }
    assert_raises(ActiveRecord::RecordNotFound) { impact_preview(after_snapshot_id: @knowledge.source_snapshot_id) }
    assert_raises(ActiveRecord::RecordNotFound) { impact_preview(source_id: @snapshot.source_id) }
    assert_raises(CorpusIntake::Invalid) { impact_preview(version_ids: [ @version.id, 2**63 - 1 ]) }
    foreign = workspaces(:beta_support).corpora.create!(name: "Foreign private corpus")
    assert_raises(ActiveRecord::RecordNotFound) { impact_preview(corpus: foreign) }
    assert_raises(Current::RoleAccessDenied) { with_impact_approval { request_impact(membership: memberships(:outsider_beta)) } }
  end

  test "new document or scenario changes stop unsent work and post-dispatch retention" do
    [ :document, :scenario ].each do |change|
      with_impact_response(calls: calls = [], during_call: -> { change == :document ? import_impact_document("Newer policy #{change} after dispatch.") : @scenario.revise!(membership: @membership, base_version_id: @scenario.current_version_id, attributes: { title: "New assumption version" }) }) do
        impact = request_impact
        AssumptionImpactJob.perform_now(impact.id)
        assert_equal "interrupted", impact.reload.state
        assert_nil impact.assumption_impact_result
        2.times { AssumptionImpactJob.perform_now(impact.id) }
        assert_equal 1, calls.size
      end
      @version_ids = @scenarios.map { |scenario| scenario.reload.current_version_id }.sort
      @after = @source.reload.current_snapshot
    end
    with_impact_response(calls: calls = []) do
      impact = request_impact
      import_impact_document("A newer change before dispatch.")
      AssumptionImpactJob.perform_now(impact.id)
      assert_empty calls
      assert_equal "interrupted", impact.reload.state
    end
  end

  test "a newer snapshot followed by an old-head revert still invalidates consent" do
    change_and_revert = lambda do
      expiry = @source.reload.expires_at
      import_impact_document("A later entitlement change #{SecureRandom.hex(4)}.")
      @source.reload.update!(current_snapshot: @after, expires_at: expiry)
    end
    with_impact_response(calls: calls = []) do
      impact = request_impact
      change_and_revert.call
      assert_equal impact.source_head_id, @source.reload.current_snapshot_id
      assert_equal impact.input.fetch("source_expires_at"), @source.expires_at.iso8601(6)
      AssumptionImpactJob.perform_now(impact.id)
      assert_empty calls
      assert_equal "interrupted", impact.reload.state
    end
    with_impact_response(calls: calls = [], during_call: change_and_revert) do
      impact = request_impact
      AssumptionImpactJob.perform_now(impact.id)
      assert_equal 1, calls.size
      assert_equal "interrupted", impact.reload.state
      assert_nil impact.assumption_impact_result
    end
  end

  test "revoked membership endpoint rejected reviews and expiry stop before and after transport" do
    with_impact_response(calls: calls = [], during_call: -> { @membership.update!(role: :viewer) }) do
      impact = request_impact
      AssumptionImpactJob.perform_now(impact.id)
      assert_equal 1, calls.size
      assert_equal "interrupted", impact.reload.state
      assert_nil impact.assumption_impact_result
    end
    @membership.update!(role: :owner)
    with_impact_approval do
      impact = request_impact(configuration: impact_configuration.deep_merge("settings" => { "seed" => 18 }))
      ENV["NAVISHAI_CORPUS_ENDPOINTS"] = "[]"
      AssumptionImpactJob.perform_now(impact.id)
      assert_equal "interrupted", impact.reload.state
      assert_nil impact.assumption_impact_result
    end
    @scenario.review!(membership: @membership, version_id: @version.id, decision: "reject", note: "Synthetic rejected assumption")
    assert_raises(CorpusIntake::Invalid) { impact_preview }
    @scenario.review!(membership: @membership, version_id: @version.id, decision: "approve", note: "Synthetic restored fixture")
    with_impact_response(calls: calls = [], during_call: -> { @knowledge.source_snapshot.source.update!(expires_at: 1.minute.ago) }) do
      impact = request_impact(configuration: impact_configuration.deep_merge("settings" => { "seed" => 19 }))
      AssumptionImpactJob.perform_now(impact.id)
      assert_equal "interrupted", impact.reload.state
      assert_nil impact.assumption_impact_result
      assert impact.expired?
      assert_raises(CorpusIntake::Invalid) { impact_preview }
    end
  end

  test "unknown outcome error abstention and crashed claim are once-only" do
    with_impact_response(response: { "schema" => "invalid" }, calls: calls = []) do
      impact = request_impact
      2.times { AssumptionImpactJob.perform_now(impact.id) }
      assert_equal "complete", impact.reload.state
      assert_equal "error", impact.assumption_impact_result.result.fetch("decision")
      assert_match(/unknown/, impact.assumption_impact_result.result.fetch("reason"))
      assert_equal impact.id, request_impact.id
      assert_equal 1, calls.size
    end
    response = impact_response.merge("decision" => "abstain", "affected" => [])
    with_impact_response(response:, calls: calls = []) do
      impact = request_impact(configuration: impact_configuration.deep_merge("settings" => { "seed" => 20 }))
      AssumptionImpactJob.perform_now(impact.id)
      assert_equal "abstain", impact.reload.assumption_impact_result.result.fetch("decision")
      crash = request_impact(configuration: impact_configuration.deep_merge("settings" => { "seed" => 21 }))
      crash.update!(state: "running", started_at: 11.minutes.ago)
      AssumptionImpactJob.perform_now(crash.id)
      assert_equal "running", crash.reload.state
      crash.interrupt!(membership: @membership)
      AssumptionImpactJob.perform_now(crash.id)
      assert_equal "interrupted", crash.reload.state
      assert_equal 1, calls.size
      assert_nil crash.assumption_impact_result
    end
  end

  test "purge clears corpus-wide disclosed copies and queued jobs cannot transmit" do
    with_impact_response(calls: calls = []) do
      impact = request_impact
      AssumptionImpactJob.perform_now(impact.id)
      queued = request_impact(configuration: impact_configuration.deep_merge("settings" => { "seed" => 22 }))
      SourcePurge.call(source: @knowledge.source_snapshot.source, membership: @membership)
      assert_equal 0, AssumptionImpact.where(corpus: @corpus).count
      assert_equal 0, AssumptionImpactResult.where(corpus: @corpus).count
      assert_equal 0, AssumptionImpactInput.where(corpus: @corpus).count
      AssumptionImpactJob.perform_now(queued.id)
      assert_equal 1, calls.size
      assert_equal({}, AuditEvent.find_by!(action: "assumption_impact.completed", subject_id: impact.id).metadata)
    end
  end
end
