require "test_helper"
require_relative "../test_helpers/batch_discovery_test_helper"

class BatchDiscoveryAccessTest < ActionDispatch::IntegrationTest
  include BatchDiscoveryTestHelper
  setup do
    build_batch_corpus
    sign_in_as users(:owner)
  end

  test "explicit batch preview binds allocation consent and retains malformed settings without queuing" do
    get new_workspace_corpus_corpus_analysis_path(@workspace, @corpus), params: { processing_method: "model_batch" }
    assert_response :success
    assert_select "input[name=processing_method][value=model_batch]"
    assert_select "h3", text: "Exact allocation and maximum call plan"
    assert_select "summary", text: /Identity 104/
    plan = batch_plan
    parameters = { processing_method: "model_batch", scenario_limit: 2, configuration: discovery_configuration.to_json,
      input_digest: plan.fetch("source_digest"), call_plan_digest: ModelCorpusDiscovery.digest(plan) }
    with_corpus_approval do
      assert_no_difference([ "CorpusAnalysis.count", "CorpusDiscoveryBatch.count" ]) do
        post workspace_corpus_corpus_analyses_path(@workspace, @corpus), params: parameters
        assert_response :unprocessable_content
        assert_select "[role=alert]", text: /Confirm disclosure/
        post workspace_corpus_corpus_analyses_path(@workspace, @corpus), params: parameters.merge(configuration: "{broken", corpus_disclose: "1")
        assert_response :unprocessable_content
        assert_select "textarea[name=configuration]", text: "{broken"
        post workspace_corpus_corpus_analyses_path(@workspace, @corpus), params: parameters.merge(call_plan_digest: "stale", corpus_disclose: "1")
        assert_response :unprocessable_content
        assert_select "[role=alert]", text: /call plan changed/
        assert_select "input#corpus_disclose[checked]", count: 0
      end
      assert_difference("CorpusDiscoveryBatch.count", 3) do
        post workspace_corpus_corpus_analyses_path(@workspace, @corpus), params: parameters.merge(corpus_disclose: "1")
        assert_response :see_other
      end
    end
  end

  test "viewer sees receipts but cannot request interrupt mine or cross workspaces" do
    with_batch_responses do
      @analysis = request_batch_analysis
      CorpusAnalysisJob.perform_now(@analysis.id)
    end
    Membership.create!(workspace: @workspace, user: users(:teammate), role: :viewer)
    sign_in_as users(:teammate)
    assert_no_difference([ "CorpusAnalysis.count", "CorpusDiscoveryBatch.count", "Scenario.count", "AuditEvent.count" ]) do
      get workspace_corpus_corpus_analysis_path(@workspace, @corpus, @analysis)
      assert_response :success
      assert_select "h2", text: "Batch progress and receipts"
      assert_select "input[type=submit]", count: 0
      get new_workspace_corpus_corpus_analysis_path(@workspace, @corpus), params: { processing_method: "model_batch" }
      assert_response :forbidden
      post workspace_corpus_corpus_analyses_path(@workspace, @corpus), params: { processing_method: "model_batch" }
      assert_response :forbidden
      post interrupt_workspace_corpus_corpus_analysis_path(@workspace, @corpus, @analysis)
      assert_response :forbidden
      post workspace_corpus_scenarios_path(@workspace, @corpus), params: { analysis_id: @analysis.id }
      assert_response :forbidden
      get workspace_corpus_corpus_analysis_path(workspaces(:beta_support), @corpus, @analysis)
      assert_response :not_found
    end
  end
end
