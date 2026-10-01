require "test_helper"
require_relative "../test_helpers/scenario_proposal_test_helper"

class ScenarioProposalAccessTest < ActionDispatch::IntegrationTest
  include ScenarioProposalTestHelper
  setup do
    build_proposal_scenario
    sign_in_as users(:owner)
  end

  test "consent configuration and old-version errors preserve edits but queue nothing" do
    path = propose_workspace_corpus_scenario_path(@workspace, @corpus, @scenario)
    parameters = { version_id: @version.id, configuration: proposal_configuration.to_json }
    with_scenario_approval do
      assert_no_difference("ScenarioProposal.count") do
        post path, params: parameters
        assert_response :unprocessable_content
        assert_select "[role=alert]", text: /Confirm disclosure/
        assert_select "textarea[name=configuration]", text: proposal_configuration.to_json
        assert_select "input#proposal_disclose[checked]", count: 0
        post path, params: parameters.merge(configuration: "{broken", proposal_disclose: "1")
        assert_response :unprocessable_content
        assert_select "textarea[name=configuration]", text: "{broken"
        @scenario.revise!(membership: @membership, base_version_id: @version.id, attributes: { title: "Expert changed this version" })
        post path, params: parameters.merge(proposal_disclose: "1")
        assert_response :unprocessable_content
        assert_select "[role=alert]", text: /current, active/
        assert_select "#model-proposal input[name=version_id][value='#{@version.id}']"
        post path, params: parameters.merge(version_id: @scenarios.find { |scenario| scenario != @scenario }.current_version_id, proposal_disclose: "1")
        assert_response :not_found
      end
    end
  end

  test "read-only review keeps proposals source-backed and escaped; foreign viewers cannot request" do
    response = proposal_response.merge("reason" => "<script>untrusted source</script>")
    with_proposal_response(response:) do
      proposal = request_proposal
      ScenarioProposalJob.perform_now(proposal.id)
    end
    Membership.create!(workspace: @workspace, user: users(:teammate), role: :viewer)
    sign_in_as users(:teammate)
    assert_no_difference([ "ScenarioProposal.count", "ScenarioProposalResult.count", "ScenarioReview.count", "AuditEvent.count" ]) do
      get workspace_corpus_scenario_path(@workspace, @corpus, @scenario)
      assert_response :success
      assert_select "h3", text: "Requirement evidence"
      assert_select "script", text: /untrusted source/, count: 0
      assert_select "a", text: "Inspect quoted source", count: 2
      assert_select "input[type=submit]", count: 0
      post propose_workspace_corpus_scenario_path(@workspace, @corpus, @scenario), params: {}
      assert_response :forbidden
      post interrupt_proposal_workspace_corpus_scenario_path(@workspace, @corpus, @scenario), params: {}
      assert_response :forbidden
      get workspace_corpus_scenario_path(workspaces(:beta_support), @corpus, @scenario)
      assert_response :not_found
    end
  end

  test "stale evidence does not prevent scenario inspection or permit a request" do
    @scenario.revise!(membership: @membership, base_version_id: @version.id, attributes: {}, evidence_item_id: @knowledge.id, evidence_kind: "knowledge", excerpt: "Request the certificate expiry date.")
    @version = @scenario.reload.current_version
    CorpusIntake.call(corpus: @corpus, membership: @membership, name: "SSO playbook", kind: "document", bytes: "New approved company policy needed.")
    get workspace_corpus_scenario_path(@workspace, @corpus, @scenario)
    assert_response :success
    assert_select "#model-proposal [role=status]", text: /documentation changed/
    assert_select "#model-proposal input[type=submit]", count: 0
    with_scenario_approval do
      post propose_workspace_corpus_scenario_path(@workspace, @corpus, @scenario), params: { version_id: @version.id, configuration: proposal_configuration.to_json, proposal_disclose: "1" }
      assert_response :unprocessable_content
      assert_equal 0, ScenarioProposal.where(corpus: @corpus).count
    end
  end
end
