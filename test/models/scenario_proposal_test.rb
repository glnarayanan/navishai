require "test_helper"
require_relative "../test_helpers/scenario_proposal_test_helper"

class ScenarioProposalTest < ActiveSupport::TestCase
  include ScenarioProposalTestHelper
  setup { build_proposal_scenario }

  test "source-processing purpose and fixed-version human consent are separate gates" do
    with_endpoint_approval do
      assert_raises(EvaluationHttp::Error) { request_proposal }
    end
    with_scenario_approval(workspace_id: workspaces(:beta_support).id) do
      assert_raises(EvaluationHttp::Error) { request_proposal }
    end
    with_scenario_approval(endpoint: "#{HTTP_ENDPOINT}/different") do
      assert_raises(EvaluationHttp::Error) { request_proposal }
    end
    with_scenario_approval do
      assert_raises(Scenario::Invalid) { request_proposal(disclose: false) }
      assert_raises(EvaluationHttp::Error) { EvaluationHttp.approval!(HTTP_ENDPOINT, workspace_id: @workspace.id) }
      assert_raises(Scenario::Invalid) { request_proposal(configuration: proposal_configuration.merge("bearer_token" => "never-store")) }
      proposal = request_proposal
      assert_equal proposal.id, request_proposal.id
      assert_equal "queued", proposal.state
      assert_equal "source-scenario-v1", proposal.processing_version
      assert_match(/\A[0-9a-f-]{36}\z/, proposal.request_key)
      assert_equal proposal_configuration, proposal.configuration
      assert_equal 1, ScenarioProposal.where(corpus: @corpus).count
    end
    assert_not AuditEvent.where(action: "scenario.proposal_requested").last.metadata.key?("configuration")
  end

  test "a claimed proposal sends minimal fixed inputs once and never changes expert work" do
    counts = [ ScenarioVersion.count, ScenarioReview.count, EvalCase.count, HumanLabel.count ]
    previous_id = @version.id
    calls = []
    with_proposal_response(calls:) do
      proposal = request_proposal
      @version.scenario_evidence.create!(workspace: @workspace, corpus: @corpus, corpus_item: @knowledge, kind: "knowledge", excerpt: "Request the certificate expiry date.")
      # A later human edit must survive an older proposal completing.
      @scenario.revise!(membership: @membership, base_version_id: previous_id, attributes: { title: "Keep the expert's later edit" })
      2.times { ScenarioProposalJob.perform_now(proposal.id) }
      assert_equal "complete", proposal.reload.state
      assert_equal "proposal", proposal.scenario_proposal_result.result["decision"]
      assert_nil proposal.scenario_proposal_result.result["cost"]
      assert_equal "endpoint_reported", proposal.scenario_proposal_result.result["usage_and_cost"]
      assert_equal previous_id, proposal.scenario_version_id
    end
    assert_equal [ counts[0] + 1, *counts.drop(1) ], [ ScenarioVersion.count, ScenarioReview.count, EvalCase.count, HumanLabel.count ]
    assert_equal "Keep the expert's later edit", @scenario.reload.current_version.title
    assert_not @scenario.current_version.approved?
    assert_equal 1, calls.size
    payload = JSON.parse(calls.sole.body)
    assert_equal %w[company_evidence instructions model schema settings starting_context], payload.keys.sort
    assert_equal "source-scenario-v1", payload["schema"]
    assert_equal 1, payload["company_evidence"].size, "Evidence attached after request cannot expand disclosure."
    assert_equal({ "situation" => "Enterprise SAML login stopped after a certificate change.", "known_facts" => { "idp" => "Okta", "plan" => "enterprise" } }, payload["starting_context"])
    assert_includes payload["instructions"], "untrusted data"
    assert_equal "Bearer test-only-scenario-token", calls.sole["Authorization"]
    [ "private diagnosis", "Expert-only prior expectation", "Webhook replay loses records", "human_labels" ].each { |text| assert_not_includes calls.sole.body, text }
  end

  test "endpoint revocation stops before sending and interrupted attempts do not retry" do
    with_scenario_approval do
      proposal = request_proposal
      proposal.interrupt!(membership: @membership)
      with_test_method(ScenarioExtractor, :call, ->(*) { flunk "Interrupted attempt sent" }) { ScenarioProposalJob.perform_now(proposal.id) }
      assert_nil proposal.reload.scenario_proposal_result
    end
    @scenario.revise!(membership: @membership, base_version_id: @version.id, attributes: { title: "New deliberate fixture version" })
    @version = @scenario.reload.current_version
    proposal = with_scenario_approval { request_proposal }
    with_test_method(ScenarioExtractor, :call, ->(*) { flunk "Revoked endpoint sent" }) { ScenarioProposalJob.perform_now(proposal.id) }
    assert_equal "interrupted", proposal.reload.state
    assert_nil proposal.scenario_proposal_result
    assert_raises(Scenario::Invalid) { with_scenario_approval { ScenarioProposal.request!(version: @scenario.scenario_versions.order(:number).first, membership: @membership, configuration: proposal_configuration, disclose: true) } }
  end

  test "membership revocation and source expiry discard queued attempts before extraction" do
    Membership.create!(workspace: @workspace, user: users(:teammate), role: :owner)
    with_scenario_approval do
      proposal = request_proposal
      @membership.update!(role: :viewer)
      with_test_method(ScenarioExtractor, :call, ->(*) { flunk "Revoked writer sent" }) { ScenarioProposalJob.perform_now(proposal.id) }
      assert_equal "interrupted", proposal.reload.state
      assert_nil proposal.scenario_proposal_result
      @membership.update!(role: :owner)
      other = @scenarios.find { |scenario| scenario != @scenario }.current_version
      proposal = request_proposal(version: other)
      @snapshot.source.update!(expires_at: 1.second.ago)
      with_test_method(ScenarioExtractor, :call, ->(*) { flunk "Expired evidence sent" }) { ScenarioProposalJob.perform_now(proposal.id) }
      assert_equal "interrupted", proposal.reload.state
      assert_nil proposal.scenario_proposal_result
    end
  end

  test "SQL freezes requests results and rejects foreign workspace and sibling corpus links; purge removes copies" do
    with_proposal_response do
      proposal = request_proposal
      ScenarioProposalJob.perform_now(proposal.id)
      result = proposal.reload.scenario_proposal_result
      assert_raises(ActiveRecord::ReadOnlyRecord) { result.update!(result: { "decision" => "error" }) }
      [ [ ScenarioProposal, proposal.id, { configuration: {} } ], [ ScenarioProposal, proposal.id, { input: {} } ], [ ScenarioProposalResult, result.id, { result: {} } ] ].each do |model, id, attributes|
        assert_raises(ActiveRecord::StatementInvalid) { model.transaction(requires_new: true) { model.where(id:).update_all(attributes) } }
      end
      sibling = @workspace.corpora.create!(name: "Sibling corpus")
      foreign = workspaces(:beta_support).corpora.create!(name: "Foreign corpus")
      unexecuted = request_proposal(version: @scenarios.find { |scenario| scenario != @scenario }.current_version)
      [ sibling, foreign ].each do |corpus|
        assert_raises(ActiveRecord::InvalidForeignKey) do
          ScenarioProposalResult.transaction(requires_new: true) { ScenarioProposalResult.create!(workspace: corpus.workspace, corpus:, scenario_proposal: unexecuted, result: { "decision" => "abstain" }, created_at: Time.current) }
        end
        assert_raises(ActiveRecord::InvalidForeignKey) do
          ScenarioProposal.transaction(requires_new: true) { ScenarioProposal.create!(workspace: corpus.workspace, corpus:, scenario_version: @scenario.scenario_versions.order(:number).first, requested_by: @membership.user, configuration: proposal_configuration, input: proposal.input, processing_version: ScenarioExtractor::VERSION, created_at: Time.current) }
        end
      end
      SourcePurge.call(source: @snapshot.source, membership: @membership)
      assert_not ScenarioProposal.exists?(proposal.id)
      assert_not ScenarioProposalResult.exists?(result.id)
    end
  end
end
