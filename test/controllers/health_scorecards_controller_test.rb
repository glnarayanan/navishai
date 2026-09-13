require "test_helper"

class HealthScorecardsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
    sign_in_as @owner.user
  end

  test "guides an owner from proposal through preview and publish" do
    get workspace_health_scorecard_path(@workspace)
    assert_response :success
    assert_select "h1", "Health scorecard"
    assert_select "form[action=?]", propose_workspace_health_scorecard_path(@workspace)
    assert_select "form[action=?]", generate_workspace_health_scorecard_path(@workspace)

    post propose_workspace_health_scorecard_path(@workspace), params: proposal_params
    version = @workspace.health_scorecard.versions.first
    assert_redirected_to workspace_health_scorecard_path(@workspace, version_id: version.id)

    post backtest_workspace_health_scorecard_path(@workspace), params: { version_id: version.id }
    assert_redirected_to workspace_health_scorecard_path(@workspace, version_id: version.id, anchor: "preview")
    post publish_workspace_health_scorecard_path(@workspace), params: {
      version_id: version.id, expected_current_version_id: @workspace.health_scorecard.current_version_id
    }
    assert_redirected_to workspace_health_scorecard_path(@workspace, version_id: version.id)
    assert_equal version, @workspace.health_scorecard.reload.current_version
  end

  test "renders invalid proposals and enforces writer and admin roles" do
    post propose_workspace_health_scorecard_path(@workspace), params: proposal_params.merge(healthy_min: 20)
    assert_response :unprocessable_content
    assert_select "[role=alert]", text: /bands must satisfy/

    manager = @workspace.memberships.create!(user: users(:teammate), role: :manager)
    sign_in_as manager.user
    post propose_workspace_health_scorecard_path(@workspace), params: proposal_params
    version = @workspace.health_scorecard.versions.first
    post backtest_workspace_health_scorecard_path(@workspace), params: { version_id: version.id }
    assert_redirected_to workspace_health_scorecard_path(@workspace, version_id: version.id, anchor: "preview")
    post publish_workspace_health_scorecard_path(@workspace), params: { version_id: version.id }
    assert_response :forbidden

    viewer = User.create!(email_address: "scorecard-viewer@example.com", password: "password12345", verified_at: Time.current)
    @workspace.memberships.create!(user: viewer, role: :viewer)
    sign_in_as viewer
    get workspace_health_scorecard_path(@workspace)
    assert_response :success
    assert_select ".scorecard-designer", count: 0
    assert_select ".scorecard-ai", count: 0
    post propose_workspace_health_scorecard_path(@workspace), params: proposal_params
    assert_response :forbidden
    post generate_workspace_health_scorecard_path(@workspace), params: { proposal_prompt: "Make approaching renewal matter more." }
    assert_response :forbidden
  end

  test "submits a runner-backed proposal and requires an explicit accept" do
    post generate_workspace_health_scorecard_path(@workspace),
      params: { proposal_prompt: "Make approaching renewal and repeated SLA breaches matter more." }
    assert_response :unprocessable_content
    assert_select ".scorecard-designer"
    assert_select "form[action=?]", propose_workspace_health_scorecard_path(@workspace)

    approve_scripted_runtime(workspace: @workspace, membership: @owner)
    published = @workspace.health_scorecard.current_version
    run = HealthScorecardProposalWorkflow.generate!(
      workspace: @workspace, membership: @owner,
      prompt: "Make approaching renewal and repeated SLA breaches matter more.", admit: false
    )
    proposal = retain_proposal(run)
    get workspace_health_scorecard_path(@workspace)
    assert_response :success
    assert_select "p", text: /increased renewal/i
    post accept_workspace_health_scorecard_path(@workspace), params: { proposal_id: proposal.id }
    version = @workspace.health_scorecard.versions.order(version_number: :desc).first
    assert_redirected_to workspace_health_scorecard_path(@workspace, version_id: version.id)
    assert_equal published, @workspace.health_scorecard.reload.current_version
    assert_equal proposal, version.source_proposal
  end

  test "revises a proposal, shows inspectable diffs, and rejects a stale tab" do
    approve_scripted_runtime(workspace: @workspace, membership: @owner)
    parent = retain_proposal(
      HealthScorecardProposalWorkflow.generate!(
        workspace: @workspace, membership: @owner,
        prompt: "Make approaching renewal and repeated SLA breaches matter more.", admit: false
      )
    )
    revision = retain_proposal(
      HealthScorecardProposalWorkflow.generate!(
        workspace: @workspace, membership: @owner,
        prompt: "Raise SLA-breach weight further and keep renewal proximity.",
        parent_proposal: parent, expected_latest_proposal_id: parent.id, admit: false
      ),
      sla_weight: 50
    )

    get workspace_health_scorecard_path(@workspace)
    assert_response :success
    assert_select ".scorecard-diff-changed", text: /SLA breaches/
    assert_select "p.scorecard-lineage", text: /Revises proposal #{parent.id}/
    assert_select "input[name=parent_proposal_id][value=?]", parent.id.to_s
    assert_select "input[name=expected_latest_proposal_id][value=?]", revision.id.to_s
    assert_select "input[name=expected_proposal_id][value=?]", revision.id.to_s

    post generate_workspace_health_scorecard_path(@workspace), params: {
      proposal_prompt: "Raise SLA-breach weight further and keep renewal proximity.",
      parent_proposal_id: parent.id, expected_latest_proposal_id: parent.id
    }
    assert_response :unprocessable_content
    assert_select "[role=alert]", text: /another proposal after the page loaded/

    post accept_workspace_health_scorecard_path(@workspace),
      params: { proposal_id: revision.id, expected_proposal_id: parent.id }
    assert_response :unprocessable_content
    assert_select "[role=alert]", text: /changed after the page loaded/
  end

  test "does not generate from a foreign parent proposal" do
    approve_scripted_runtime(workspace: @workspace, membership: @owner)
    parent = retain_proposal(
      HealthScorecardProposalWorkflow.generate!(
        workspace: @workspace, membership: @owner,
        prompt: "Make approaching renewal and repeated SLA breaches matter more.", admit: false
      )
    )
    sign_in_as users(:outsider)
    post generate_workspace_health_scorecard_path(workspaces(:beta_support)), params: {
      proposal_prompt: "Raise SLA-breach weight further and keep renewal proximity.",
      parent_proposal_id: parent.id
    }
    assert_response :not_found
  end

  test "does not expose a foreign workspace version" do
    foreign = HealthScorecardDesigner.install_default!(workspace: workspaces(:beta_support)).current_version
    get workspace_health_scorecard_path(@workspace, version_id: foreign.id)
    assert_response :not_found
    post backtest_workspace_health_scorecard_path(@workspace), params: { version_id: foreign.id }
    assert_response :not_found
    post accept_workspace_health_scorecard_path(@workspace), params: { proposal_id: foreign.id }
    assert_response :not_found
  end

  private
    def proposal_params
      {
        goal_prompt: "Focus the score on clear renewal risk.", healthy_min: 75, watch_min: 50,
        signals: {
          open_cases: { enabled: "1", weight: 30 },
          sla_breaches: { enabled: "0", weight: 25 }
        }
      }
    end

    def retain_proposal(run, sla_weight: 35)
      ledger = ExecutionLedger.new(workspace: @workspace)
      time = Time.current.change(usec: 0)
      [
        [ 1, "run.admitted", { workspace_key: @workspace.runner_key, task_key: run.crew_task.task_key, attempt: run.attempt_number } ],
        [ 2, "run.started", { adapter: "scripted", scenario: "scorecard", attempt: run.attempt_number } ],
        [ 3, "output.produced", { text: JSON.generate(
          schema_version: 1, kind: "scorecard_proposal",
          definition: {
            "schema_version" => 1, "healthy_min" => 75, "watch_min" => 50,
            "rules" => [
              { "signal_key" => "renewal_on", "weight" => 40 },
              { "signal_key" => "sla_breaches", "weight" => sla_weight }
            ]
          },
          explanation: "I increased renewal proximity and SLA breach weights using only catalog signals.",
          assumptions: [ "Only retained catalog signals can change the score." ],
          unsupported_requests: [], missing_evidence: []
        ) } ],
        [ 4, "run.completed", { outcome: "completed" } ]
      ].each do |sequence, type, data|
        ledger.ingest!(event: {
          "protocol_version" => "v1", "event_id" => SecureRandom.uuid, "run_id" => run.run_key,
          "sequence" => sequence, "event_type" => type,
          "occurred_at" => (time + sequence.seconds).iso8601(6), "data" => data.deep_stringify_keys
        })
      end
      @workspace.health_scorecard_proposals.find_by!(execution_run: run)
    end
end
