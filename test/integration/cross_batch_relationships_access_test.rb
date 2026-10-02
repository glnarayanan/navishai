require "test_helper"
require "stringio"
require_relative "../test_helpers/relationship_discovery_test_helper"

class CrossBatchRelationshipsAccessTest < ActionDispatch::IntegrationTest
  include RelationshipDiscoveryTestHelper
  include ActiveJob::TestHelper

  setup do
    build_relationship_corpus
    sign_in_as users(:owner)
  end

  test "native v3 preview and repair bind consent to its exact plan without queuing on refusal" do
    plan = batch_plan(version: BatchCorpusDiscovery::RELATIONSHIPS_VERSION)
    get new_workspace_corpus_corpus_analysis_path(@workspace, @corpus), params: { processing_method: "model_batch_relationships" }
    assert_response :success
    assert_select "input[name=processing_method][value=model_batch_relationships]"
    assert_select "input[name=call_plan_digest][value=?]", ModelCorpusDiscovery.digest(plan)
    assert_select "p", text: /cross-batch support relationships · v3/
    parameters = { processing_method: "model_batch_relationships", scenario_limit: 2, configuration: discovery_configuration.to_json,
      input_digest: plan.fetch("source_digest"), call_plan_digest: ModelCorpusDiscovery.digest(plan) }
    with_corpus_approval do
      assert_no_difference([ "CorpusAnalysis.count", "CorpusAnalysisInput.count", "CorpusDiscoveryBatch.count" ]) do
        assert_no_enqueued_jobs do
          post workspace_corpus_corpus_analyses_path(@workspace, @corpus), params: parameters.merge(configuration: "{broken")
          assert_response :unprocessable_content
          assert_select "[role=alert]", text: /valid JSON/
          assert_select "input[name=processing_method][value=model_batch_relationships]"
          post workspace_corpus_corpus_analyses_path(@workspace, @corpus), params: parameters
          assert_response :unprocessable_content
          assert_select "[role=alert]", text: /Confirm disclosure/
          assert_select "input#corpus_disclose[checked]", count: 0
          old = batch_plan(version: BatchCorpusDiscovery::OBSERVATIONS_VERSION)
          post workspace_corpus_corpus_analyses_path(@workspace, @corpus), params: parameters.merge(corpus_disclose: "1", call_plan_digest: ModelCorpusDiscovery.digest(old))
          assert_response :unprocessable_content
          assert_select "[role=alert]", text: /call plan changed/
        end
      end
      assert_enqueued_with(job: CorpusAnalysisJob) do
        post workspace_corpus_corpus_analyses_path(@workspace, @corpus), params: parameters.merge(corpus_disclose: "1")
        assert_response :see_other
      end
    end
    analysis = @corpus.corpus_analyses.sole
    assert_equal "support-corpus-batch-v3", analysis.processing_method
    assert_equal plan, analysis.call_plan
    calls = []
    with_relationship_responses(calls:) { 2.times { CorpusAnalysisJob.perform_now(analysis.id) } }
    assert_equal 3, calls.size
    assert_equal "complete", analysis.reload.state, analysis.error
    get workspace_corpus_corpus_analysis_path(@workspace, @corpus, analysis)
    assert_response :success
    assert_select "#support-relationships details", count: 1
    assert_select "#support-relationships article", count: 2
    assert_select "#support-relationships h3", text: "Uncertainty"
    assert_select "#support-relationships pre", text: @items.fetch("report-99").content
    assert_select "#support-relationships p", text: /Fixed observation: .*\/observation\/0 · evidence index 0/, count: 2
    assert_select "#support-observations article", count: 4
    assert_equal [ 0, 0 ], [ Scenario.count, HumanLabel.count ]
  end

  test "historical relationship anchors remain read-only tenant scoped and unavailable after expiry and purge" do
    analysis = nil
    with_relationship_responses do
      analysis = request_relationship_analysis
      CorpusAnalysisJob.perform_now(analysis.id)
    end
    old_item = @items.fetch("report-99")
    CorpusIntake.call(corpus: @corpus, membership: @membership, name: "History", kind: "conversations",
      bytes: [ { id: "report-99", title: "Replacement", content: "Different current source without the old ordering." } ].to_json)
    Membership.create!(workspace: @workspace, user: users(:teammate), role: :viewer)
    sign_in_as users(:teammate)
    assert_no_difference([ "CorpusAnalysis.count", "Scenario.count", "HumanLabel.count", "AuditEvent.count" ]) do
      get workspace_corpus_corpus_analysis_path(@workspace, @corpus, analysis)
      assert_response :success
      assert_select "#support-relationships pre", text: old_item.content
      assert_select "#support-relationships a[href=?]", workspace_corpus_source_path(@workspace, @corpus, @snapshot.source_id,
        snapshot: 2, page: 2, anchor: "record-#{old_item.id}")
      assert_select "main form[method=post]", count: 0
      post workspace_corpus_corpus_analyses_path(@workspace, @corpus), params: { processing_method: "model_batch_relationships" }
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
    assert_not CorpusDiscoveryBatch.exists?(corpus_analysis_id: analysis.id)
  end

  test "v3 native result writes filter private text and existing SQL guards bind immutable receipts to their tenant" do
    previous_logger = ActiveRecord::Base.logger
    buffer = StringIO.new
    ActiveRecord::Base.logger = ActiveSupport::Logger.new(buffer, level: Logger::DEBUG)
    analysis = nil
    with_relationship_responses(change: ->(response, payload) do
      response["relationships"].sole["summary"] = "private81-new-relationship" if payload["schema"] == BatchCorpusDiscovery::MERGE_RELATIONSHIPS_VERSION
    end) do
      analysis = request_relationship_analysis
      CorpusAnalysisJob.perform_now(analysis.id)
    end
    result = analysis.corpus_analysis_result
    assert_equal "private81-new-relationship", result.result.fetch("relationships").sole.fetch("summary")
    assert_includes buffer.string, '["result", "[FILTERED]"]'
    assert_not_includes buffer.string, "private81-new-relationship"
    assert_not_includes buffer.string, @items.fetch("report-99").content
    [ [ "corpus_analysis_results", result.id, "result = '{}'::jsonb" ],
      [ "corpus_discovery_batches", analysis.corpus_discovery_batches.first.id, "result = '{}'::jsonb" ],
      [ "corpus_analyses", analysis.id, "processing_method = 'support-corpus-batch-v2'" ] ].each do |table, id, change|
      assert_raises(ActiveRecord::StatementInvalid) do
        ActiveRecord::Base.transaction(requires_new: true) { ActiveRecord::Base.connection.execute("UPDATE #{table} SET #{change} WHERE id = #{id.to_i}") }
      end
    end
    other_attempt = nil
    with_corpus_approval { other_attempt = request_relationship_analysis }
    error = assert_raises(ActiveRecord::InvalidForeignKey) do
      ActiveRecord::Base.transaction(requires_new: true) do
        CorpusAnalysisResult.create!(workspace: workspaces(:beta_support), corpus: @corpus, corpus_analysis: other_attempt, result: { "decision" => "proposal" })
      end
    end
    assert_instance_of PG::ForeignKeyViolation, error.cause
    assert_nil other_attempt.reload.corpus_analysis_result
    assert_equal "support-corpus-global-v3", result.reload.result.fetch("schema")
  ensure
    ActiveRecord::Base.logger = previous_logger
  end
end
