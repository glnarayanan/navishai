require "test_helper"
require_relative "../test_helpers/batch_discovery_test_helper"

class SupportObservationsAccessTest < ActionDispatch::IntegrationTest
  include BatchDiscoveryTestHelper
  include ActiveJob::TestHelper

  setup do
    build_discovery_corpus
    sign_in_as users(:owner)
  end

  test "explicit single v2 preview retains repair and publishes every fixed anchor through the real job" do
    get new_workspace_corpus_corpus_analysis_path(@workspace, @corpus), params: { processing_method: "model_observations" }
    assert_response :success
    assert_select "input[name=processing_method][value=model_observations]"
    assert_select "p", text: /source-backed support observations · v2/
    parameters = { processing_method: "model_observations", scenario_limit: 2, configuration: discovery_configuration.to_json,
      input_digest: ModelCorpusDiscovery.digest(discovery_input) }
    with_corpus_approval do
      assert_no_difference([ "CorpusAnalysis.count", "CorpusAnalysisInput.count" ]) do
        assert_no_enqueued_jobs do
          post workspace_corpus_corpus_analyses_path(@workspace, @corpus), params: parameters
          assert_response :unprocessable_content
          assert_select "[role=alert]", text: /Confirm disclosure/
          assert_select "input#corpus_disclose[checked]", count: 0
          assert_select "input[name=processing_method][value=model_observations]"
        end
      end
      assert_enqueued_with(job: CorpusAnalysisJob) do
        post workspace_corpus_corpus_analyses_path(@workspace, @corpus), params: parameters.merge(corpus_disclose: "1")
      end
    end
    analysis = @corpus.corpus_analyses.sole
    assert_equal "support-corpus-v2", analysis.processing_method
    assert analysis.model?
    assert_not analysis.batch?
    calls = []
    with_batch_responses(calls:) { 2.times { CorpusAnalysisJob.perform_now(analysis.id) } }
    assert_equal [ "support-corpus-v2" ], calls.map { |request| JSON.parse(request.body).fetch("schema") }
    assert_equal "complete", analysis.reload.state, analysis.error
    assert_equal 1, analysis.corpus_analysis_result.result.fetch("observations").size
    get workspace_corpus_corpus_analysis_path(@workspace, @corpus, analysis)
    assert_response :success
    assert_select "#support-observations details", count: 1
    assert_select "#support-observations article", count: 2
    assert_select "#support-observations pre", text: @items.fetch("rare").content
    assert_select "#support-observations a[href=?]", workspace_corpus_source_path(@workspace, @corpus, @document.source_snapshot.source_id,
      snapshot: 1, page: 1, anchor: "record-#{@document.id}")
    assert_select "#support-observations h3", text: "Uncertainty"
    assert_equal 0, Scenario.count
    assert_equal 0, HumanLabel.count
  end

  test "batch v2 binds its own plan at preview request and processing while v1 defaults stay fixed" do
    build_batch_corpus
    old_plan = batch_plan
    plan = batch_plan(version: BatchCorpusDiscovery::OBSERVATIONS_VERSION)
    assert_equal "support-corpus-v1", ModelCorpusDiscovery::VERSION
    assert_equal "support-corpus-batch-v1", BatchCorpusDiscovery::VERSION
    assert_not old_plan.key?("schema")
    assert_equal "support-corpus-batch-v2", plan.fetch("schema")
    assert_equal "support-corpus-merge-v2", plan.fetch("reducer")
    assert_equal old_plan.fetch("batches"), plan.fetch("batches")
    assert_equal 3, plan.fetch("maximum_calls")
    get new_workspace_corpus_corpus_analysis_path(@workspace, @corpus), params: { processing_method: "model_batch_observations" }
    assert_response :success
    assert_select "input[name=processing_method][value=model_batch_observations]"
    assert_select "input[name=call_plan_digest][value=?]", ModelCorpusDiscovery.digest(plan)
    with_corpus_approval do
      assert_no_difference([ "CorpusAnalysis.count", "CorpusDiscoveryBatch.count" ]) do
        post workspace_corpus_corpus_analyses_path(@workspace, @corpus), params: {
          processing_method: "model_batch_observations", scenario_limit: 2, configuration: discovery_configuration.to_json,
          corpus_disclose: "1", input_digest: plan.fetch("source_digest"), call_plan_digest: ModelCorpusDiscovery.digest(old_plan) }
        assert_response :unprocessable_content
        assert_select "[role=alert]", text: /call plan changed/
      end
    end
    calls = []
    with_batch_responses(calls:) do
      analysis = request_batch_analysis(processing_method: "model_batch_observations")
      assert_equal "support-corpus-batch-v2", analysis.processing_method
      assert_equal plan, analysis.call_plan
      2.times { CorpusAnalysisJob.perform_now(analysis.id) }
      assert_equal "complete", analysis.reload.state, analysis.error
      assert_equal [ "support-corpus-v2", "support-corpus-v2", "support-corpus-merge-v2" ], calls.map { |request| JSON.parse(request.body).fetch("schema") }
      assert_equal 2, analysis.corpus_analysis_result.result.fetch("observations").size
      assert_equal %w[proposal proposal proposal], analysis.corpus_discovery_batches.order(:position).pluck(:state)
      get workspace_corpus_corpus_analysis_path(@workspace, @corpus, analysis)
      assert_response :success
      assert_select "#support-observations article", count: 4
      assert_select "#support-observations pre", text: @items.fetch("identity-98").content
      assert_select "#support-observations pre", text: @items.fetch("rare").content
    end
  end

  test "v2 follows real revocation guards and retains no partial global findings" do
    build_batch_corpus
    calls = []
    with_batch_responses(calls:, after_call: ->(_) { ENV["NAVISHAI_CORPUS_ENDPOINTS"] = "[]" }) do
      analysis = request_batch_analysis(processing_method: "model_batch_observations")
      2.times { CorpusAnalysisJob.perform_now(analysis.id) }
      assert_equal "failed", analysis.reload.state
      assert_nil analysis.corpus_analysis_result
      assert_empty analysis.issue_clusters
      assert_equal %w[error queued queued], analysis.corpus_discovery_batches.order(:position).pluck(:state)
    end
    assert_equal 1, calls.size
  end

  test "v2 fixed quotes survive replacement but not expiry foreign access or purge" do
    analysis = nil
    with_batch_responses do
      analysis = request_model_analysis(processing_method: "model_observations")
      CorpusAnalysisJob.perform_now(analysis.id)
    end
    old_item = @items.fetch("rare")
    CorpusIntake.call(corpus: @corpus, membership: @membership, name: "History", kind: "conversations",
      bytes: [ { id: "rare", title: "Current replacement", content: "Different current private source." } ].to_json)
    Membership.create!(workspace: @workspace, user: users(:teammate), role: :viewer)
    sign_in_as users(:teammate)
    assert_no_difference([ "CorpusAnalysis.count", "Scenario.count", "AuditEvent.count" ]) do
      get workspace_corpus_corpus_analysis_path(@workspace, @corpus, analysis)
      assert_response :success
      assert_select "#support-observations pre", text: old_item.content
      assert_select "#support-observations a[href=?]", workspace_corpus_source_path(@workspace, @corpus, @snapshot.source_id,
        snapshot: 1, page: 1, anchor: "record-#{old_item.id}")
      assert_select "main form[method=post]", count: 0
      post workspace_corpus_corpus_analyses_path(@workspace, @corpus), params: { processing_method: "model_observations" }
      assert_response :forbidden
      get workspace_corpus_corpus_analysis_path(workspaces(:beta_support), @corpus, analysis)
      assert_response :not_found
    end
    @snapshot.source.update!(expires_at: 1.minute.ago)
    get workspace_corpus_corpus_analysis_path(@workspace, @corpus, analysis)
    assert_response :not_found
    SourcePurge.call(source: @snapshot.source, membership: @membership)
    assert_not CorpusAnalysis.exists?(analysis.id)
    assert_not CorpusAnalysisResult.exists?(corpus_analysis_id: analysis.id)
  end

  test "legacy results lack observations without being reinterpreted as empty v2 discoveries" do
    with_discovery_response do
      analysis = request_model_analysis
      CorpusAnalysisJob.perform_now(analysis.id)
      get workspace_corpus_corpus_analysis_path(@workspace, @corpus, analysis)
      assert_response :success
      assert_select "#support-observations", count: 0
      assert_select "p", text: /v1 protocol did not request support observations/
      assert_not analysis.corpus_analysis_result.result.key?("observations")
    end
  end
end
