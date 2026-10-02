require "test_helper"
require_relative "../test_helpers/model_discovery_test_helper"

class ModelDiscoveryAccessTest < ActionDispatch::IntegrationTest
  include ModelDiscoveryTestHelper
  setup do
    build_discovery_corpus
    sign_in_as users(:owner)
  end

  test "invalid configuration consent and changed preview retain input and queue nothing" do
    path = workspace_corpus_corpus_analyses_path(@workspace, @corpus)
    parameters = { processing_method: "model", scenario_limit: 2, configuration: discovery_configuration.to_json, input_digest: ModelCorpusDiscovery.digest(discovery_input) }
    with_corpus_approval do
      assert_no_difference("CorpusAnalysis.count") do
        post path, params: parameters
        assert_response :unprocessable_content
        assert_select "[role=alert]", text: /Confirm disclosure/
        assert_select "textarea[name=configuration]", text: discovery_configuration.to_json
        assert_select "input#corpus_disclose[checked]", count: 0
        post path, params: parameters.merge(configuration: "{incomplete", corpus_disclose: "1")
        assert_response :unprocessable_content
        assert_select "textarea[name=configuration]", text: "{incomplete"
        post path, params: parameters.merge(configuration: "null", corpus_disclose: "1")
        assert_response :unprocessable_content
      end
      CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Additional SOP", kind: "document", bytes: "New company evidence.")
      assert_no_difference("CorpusAnalysis.count") do
        post path, params: parameters.merge(corpus_disclose: "1")
        assert_response :unprocessable_content
        assert_select "[role=alert]", text: /preview changed/
        assert_select "input[name=input_digest][value='#{parameters[:input_digest]}']", count: 0
        assert_select "input#corpus_disclose[checked]", count: 0
        assert_select "summary", text: /Additional SOP/
      end
    end
  end

  test "viewers inspect escaped model evidence but cannot request interrupt or cross a workspace" do
    response = discovery_response.merge("reason" => "<script>untrusted proposal</script>")
    with_discovery_response(response:) do
      @analysis = request_model_analysis
      CorpusAnalysisJob.perform_now(@analysis.id)
    end
    Membership.create!(workspace: @workspace, user: users(:teammate), role: :viewer)
    sign_in_as users(:teammate)
    assert_no_difference([ "CorpusAnalysis.count", "CorpusAnalysisResult.count", "AuditEvent.count", "TaxonomyVersion.count" ]) do
      get workspace_corpus_corpus_analysis_path(@workspace, @corpus, @analysis)
      assert_response :success
      assert_select "script", text: /untrusted proposal/, count: 0
      assert_select "h3", text: "Membership quote", count: 3
      assert_select "input[type=submit]", count: 0
      get new_workspace_corpus_corpus_analysis_path(@workspace, @corpus)
      assert_response :forbidden
      post workspace_corpus_corpus_analyses_path(@workspace, @corpus), params: {}
      assert_response :forbidden
      post interrupt_workspace_corpus_corpus_analysis_path(@workspace, @corpus, @analysis)
      assert_response :forbidden
      get workspace_corpus_corpus_analysis_path(workspaces(:beta_support), @corpus, @analysis)
      assert_response :not_found
    end
    @snapshot.source.update!(expires_at: 1.minute.ago)
    get workspace_corpus_corpus_analysis_path(@workspace, @corpus, @analysis)
    assert_response :not_found
  end
end
