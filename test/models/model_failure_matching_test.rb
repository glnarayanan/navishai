require "test_helper"
require_relative "../test_helpers/model_failure_matching_test_helper"

class ModelFailureMatchingTest < ActiveSupport::TestCase
  include ModelFailureMatchingTestHelper
  setup { build_model_matching_fixture }

  test "matching needs separate exact-purpose approval and data endpoint settings consent" do
    with_endpoint_approval { assert_raises(EvaluationHttp::Error) { request_matching } }
    %w[NAVISHAI_SCENARIO_ENDPOINTS NAVISHAI_CORPUS_ENDPOINTS NAVISHAI_IMPACT_ENDPOINTS NAVISHAI_TRACE_DISCOVERY_ENDPOINTS].each do |name|
      original = ENV[name]
      begin
        ENV[name] = [ { workspace_id: @workspace.id, endpoint: HTTP_ENDPOINT } ].to_json
        assert_raises(EvaluationHttp::Error) { request_matching }
      ensure
        original ? ENV[name] = original : ENV.delete(name)
      end
    end
    with_matching_approval(workspace_id: workspaces(:beta_support).id) { assert_raises(EvaluationHttp::Error) { request_matching } }
    with_matching_approval(endpoint: "#{HTTP_ENDPOINT}/other") { assert_raises(EvaluationHttp::Error) { request_matching } }
    with_matching_approval do
      assert_raises(Scenario::Invalid) { request_matching(disclose: false) }
      assert_raises(Scenario::Invalid) { request_matching(endpoint_confirmation: "#{HTTP_ENDPOINT}/other") }
      assert_raises(Scenario::Invalid) { request_matching(input_digest: "stale") }
      assert_raises(Scenario::Invalid) { request_matching(configuration: matching_configuration.merge("model" => "changed-after-preview")) }
      assert_raises(Scenario::Invalid) { request_matching(configuration: matching_configuration.merge("bearer_token" => "never-store")) }
      assert_raises(Scenario::Invalid) { request_matching(configuration: []) }
      request = request_matching
      assert_equal request.id, request_matching.id
      assert_equal 3, request.model_failure_matching_candidates.count
      assert_equal [ @version.id, @paraphrase.id, @negated.id ].sort, request.model_failure_matching_candidates.pluck(:scenario_version_id).sort
      assert_equal "queued", request.state
      assert_match(/\A[0-9a-f-]{36}\z/, request.request_key)
    end
    assert_equal({}, AuditEvent.where(action: "trace.matching_requested").last.metadata)
  end

  test "native claim sends complete fixed data once and retains quoted decisions without expert writes" do
    counts = [ ScenarioVersion.count, ScenarioReview.count, TraceScenarioDecision.count, HumanLabel.count, RegressionCase.count, EvalCase.count ]
    calls = []
    with_matching_response(calls:) do
      request = request_matching
      2.times { ModelFailureMatchingJob.perform_now(request.id) }
      assert_equal "complete", request.reload.state
      result = request.model_failure_matching_result.result
      assert_equal({ @paraphrase.id => "match", @negated.id => "no_match", @version.id => "uncertain" }, result["suggestions"].to_h { |entry| [ entry["scenario_version_id"], entry["decision"] ] })
      assert_nil result["cost"]
      assert_equal({ "input_tokens" => 811, "output_tokens" => 303 }, result["usage"])
      assert_equal "endpoint_reported", result["usage_and_cost"]
      assert_operator result["elapsed_ms"], :>=, 0
      assert_equal request.id, request_matching.id
      assert_equal request.request_key, calls.sole["Idempotency-Key"]
      assert_equal "Bearer test-only-matching-token", calls.sole["Authorization"]
      payload = JSON.parse(calls.sole.body)
      assert_equal %w[candidates instructions model schema settings trace], payload.keys.sort
      assert_equal "model-failure-matching-v1", payload["schema"]
      assert_equal [ @version.id, @paraphrase.id, @negated.id ].sort, payload["candidates"].pluck("scenario_version_id").sort
      assert_equal "Traffic ceiling reached; wait before resending.", payload["trace"]["input"]["situation"]
      assert_equal "I will resend immediately.", payload["trace"]["output"]["messages"].sole["content"]
      assert_equal "Assistant resends immediately.", payload["trace"]["observed_failure"]
      %w[PRIVATE_HIDDEN_FACT PRIVATE_REVIEW_NOTE PRIVATE_IMPORTED_CORRECTION].each { |text| assert_not_includes calls.sole.body, text }
    end
    assert_equal 1, calls.size
    assert_equal counts, [ ScenarioVersion.count, ScenarioReview.count, TraceScenarioDecision.count, HumanLabel.count, RegressionCase.count, EvalCase.count ]
  end

  test "unknown outcome and malformed output are terminal errors not no-match or a retry" do
    calls = 0
    with_matching_approval do
      request = request_matching
      with_test_method(Resolv, :getaddresses, ->(*) { [ "93.184.216.34" ] }) do
        with_test_method(EvaluationHttp, :perform, ->(*) { calls += 1; raise EvaluationHttp::Error, "PRIVATE_REMOTE_FAILURE" }) do
          2.times { ModelFailureMatchingJob.perform_now(request.id) }
          assert_equal request.id, request_matching.id
        end
      end
      assert_equal "complete", request.reload.state
      assert_equal "error", request.model_failure_matching_result.result["decision"]
      assert_includes request.model_failure_matching_result.result["reason"], "outcome/cost may be unknown"
      assert_not_includes request.model_failure_matching_result.result.to_json, "PRIVATE_REMOTE_FAILURE"
    end
    assert_equal 1, calls
    @paraphrase = @paraphrase.scenario.revise!(membership: @membership, base_version_id: @paraphrase.id, attributes: { title: "New fixed quota version" })
    malformed = matching_response
    malformed["suggestions"][0]["evidence"][1]["quote"] = "Invented quote"
    with_matching_response(response: malformed) do
      request = request_matching
      ModelFailureMatchingJob.perform_now(request.id)
      assert_equal "error", request.reload.model_failure_matching_result.result["decision"]
      assert_nil request.model_failure_matching_result.result["suggestions"]
    end
  end

  test "new candidate new review revision and expiry invalidate consent before transport" do
    with_matching_approval do
      input = ModelFailureMatcher.input(@item)
      request = request_matching
      @paraphrase.scenario.review!(membership: @membership, version_id: @paraphrase.id, decision: "approve", note: "A later expert review")
      assert_raises(Scenario::Invalid) { request_matching(input_digest: ModelFailureMatcher.digest(input)) }
      with_test_method(ModelFailureMatcher, :call, ->(*) { flunk "Stale review sent" }) { ModelFailureMatchingJob.perform_now(request.id) }
      assert_equal "interrupted", request.reload.state
      assert_nil request.model_failure_matching_result

      request = request_matching
      matching_version(title: "Added eligible candidate")
      with_test_method(ModelFailureMatcher, :call, ->(*) { flunk "Expanded set sent" }) { ModelFailureMatchingJob.perform_now(request.id) }
      assert_equal "interrupted", request.reload.state

      request = request_matching
      @paraphrase.scenario.revise!(membership: @membership, base_version_id: @paraphrase.id, attributes: { title: "New scenario version" })
      with_test_method(ModelFailureMatcher, :call, ->(*) { flunk "Revised candidate sent" }) { ModelFailureMatchingJob.perform_now(request.id) }
      assert_equal "interrupted", request.reload.state

      request = request_matching
      @document.source_snapshot.source.update!(expires_at: 1.second.ago)
      with_test_method(ModelFailureMatcher, :call, ->(*) { flunk "Expired input sent" }) { ModelFailureMatchingJob.perform_now(request.id) }
      assert_equal "interrupted", request.reload.state
      assert_nil request.model_failure_matching_result
    end
  end

  test "endpoint and membership revocation block queued work while changes during transport discard results" do
    request = with_matching_approval { request_matching }
    with_test_method(ModelFailureMatcher, :call, ->(*) { flunk "Revoked purpose sent" }) { ModelFailureMatchingJob.perform_now(request.id) }
    assert_equal "interrupted", request.reload.state
    Membership.create!(workspace: @workspace, user: users(:teammate), role: :owner)
    with_matching_approval do
      @paraphrase = @paraphrase.scenario.revise!(membership: @membership, base_version_id: @paraphrase.id, attributes: { title: "Different fixed preview" })
      request = request_matching
      @membership.update!(role: :viewer)
      with_test_method(ModelFailureMatcher, :call, ->(*) { flunk "Revoked writer sent" }) { ModelFailureMatchingJob.perform_now(request.id) }
      assert_equal "interrupted", request.reload.state
      @membership.update!(role: :owner)
      @paraphrase = @paraphrase.scenario.revise!(membership: @membership, base_version_id: @paraphrase.id, attributes: { title: "Transport return preview" })
      request = request_matching
      response = matching_response
      with_test_method(ModelFailureMatcher, :call, ->(*) { @negated.scenario.review!(membership: @membership, version_id: @negated.id, decision: "reject"); response }) do
        ModelFailureMatchingJob.perform_now(request.id)
      end
      assert_equal "interrupted", request.reload.state
      assert_nil request.model_failure_matching_result
    end
  end

  test "SQL freezes receipts rejects foreign lineage and deletion removes every disclosed copy" do
    with_matching_response do
      request = request_matching
      ModelFailureMatchingJob.perform_now(request.id)
      result = request.reload.model_failure_matching_result
      candidate = request.model_failure_matching_candidates.first
      assert_raises(ActiveRecord::ReadOnlyRecord) { result.update!(result: { "decision" => "error" }) }
      [ [ ModelFailureMatching, request.id, { input: {} } ], [ ModelFailureMatching, request.id, { configuration: {} } ],
        [ ModelFailureMatching, request.id, { input_digest: "0" * 64 } ], [ ModelFailureMatchingCandidate, candidate.id, { scenario_version_id: @negated.id } ],
        [ ModelFailureMatchingResult, result.id, { result: { "decision" => "error" } } ] ].each do |model, id, attributes|
        assert_raises(ActiveRecord::StatementInvalid) { model.transaction(requires_new: true) { model.where(id:).update_all(attributes) } }
      end
      [ @workspace.corpora.create!(name: "Sibling corpus"), workspaces(:beta_support).corpora.create!(name: "Foreign corpus") ].each do |corpus|
        assert_raises(ActiveRecord::InvalidForeignKey) do
          ModelFailureMatching.transaction(requires_new: true) do
            ModelFailureMatching.create!(workspace: corpus.workspace, corpus:, corpus_item: @item, requested_by: @membership.user,
              configuration: matching_configuration, input: request.input, input_digest: "0" * 64, processing_version: ModelFailureMatcher::VERSION, created_at: Time.current)
          end
        end
        assert_raises(ActiveRecord::InvalidForeignKey) do
          ModelFailureMatchingCandidate.transaction(requires_new: true) do
            ModelFailureMatchingCandidate.create!(workspace: corpus.workspace, corpus:, model_failure_matching: request, scenario_version: @paraphrase.scenario.scenario_versions.order(:id).first)
          end
        end
      end
      @paraphrase.scenario.delete
      assert_not ModelFailureMatching.exists?(request.id)
      assert_not ModelFailureMatchingResult.exists?(result.id)
      assert_empty ModelFailureMatchingCandidate.where(model_failure_matching_id: request.id)
    end
  end

  test "SQL rejects foreign result lineage and missing or null decisions without model validation" do
    with_matching_approval do
      request = request_matching
      sibling = @workspace.corpora.create!(name: "Sibling result corpus")
      assert_raises(ActiveRecord::InvalidForeignKey) do
        ModelFailureMatchingResult.transaction(requires_new: true) do
          ModelFailureMatchingResult.insert_all!([ { workspace_id: @workspace.id, corpus_id: sibling.id,
            model_failure_matching_id: request.id, result: matching_response, created_at: Time.current } ])
        end
      end
      [ {}, { "decision" => nil } ].each do |result|
        assert_raises(ActiveRecord::StatementInvalid) do
          ModelFailureMatchingResult.transaction(requires_new: true) do
            ModelFailureMatchingResult.insert_all!([ { workspace_id: @workspace.id, corpus_id: @corpus.id,
              model_failure_matching_id: request.id, result:, created_at: Time.current } ])
          end
        end
      end
      assert_nil request.model_failure_matching_result
    end
  end

  test "source purge cascades through requests even when the source is only candidate evidence" do
    with_matching_response do
      request = request_matching
      ModelFailureMatchingJob.perform_now(request.id)
      result_id = request.reload.model_failure_matching_result.id
      SourcePurge.call(source: @document.source_snapshot.source, membership: @membership)
      assert_not ModelFailureMatching.exists?(request.id)
      assert_not ModelFailureMatchingResult.exists?(result_id)
      assert_empty ModelFailureMatchingCandidate.where(corpus: @corpus)
    end
  end
end
