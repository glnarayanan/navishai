require "test_helper"

class ScorecardProposalJourneyTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
    @scorecard = HealthScorecardDesigner.install_default!(workspace: @workspace)
    @published = @scorecard.current_version
    @account = @workspace.accounts.create!(name: "Scorecard Journey")
    @at = Time.zone.parse("2026-08-24 12:00:00")
    AccountHealth.recalculate!(workspace: @workspace, account: @account,
      trigger_kind: "human_request", membership: @owner, at: @at)
    @prior_assessment = @account.health_assessments.order(:id).last
    approve_scripted_runtime(workspace: @workspace, membership: @owner)
  end

  test "propose revise inspect and publish remain one lineage without scoring on generate" do
    parent_run = generate_proposal("Make approaching renewal and repeated SLA breaches matter more.")
    parent = complete_run(parent_run, proposal_output(renewal: 40, sla: 35,
      explanation: "I increased renewal proximity and SLA breach weights using only catalog signals. This does not calculate account scores."))

    assert parent.valid_status?
    assert_equal @published, @scorecard.reload.current_version
    assert_equal @prior_assessment.score, @account.health_assessments.order(:id).last.score
    assert_nil @workspace.crew_artifacts.find_by(execution_run: parent_run)

    revision_run = generate_proposal(
      "Raise SLA-breach weight further and keep renewal proximity.",
      parent_proposal: parent, expected_latest_proposal_id: parent.id
    )
    revision = complete_run(revision_run, proposal_output(renewal: 40, sla: 50,
      explanation: "I raised the SLA-breach weight further and kept renewal proximity. This does not calculate account scores."))
    sla_diff = revision.inspectable_diff(parent.proposed_definition).fetch("rules")
      .find { |rule| rule["signal_key"] == "sla_breaches" }

    assert_equal parent, revision.parent_proposal
    assert_includes revision_run.crew_task.input_context, parent.execution_run.run_key
    assert_equal "changed", sla_diff.fetch("kind")
    assert_equal 35, sla_diff.fetch("from_weight")
    assert_equal 50, sla_diff.fetch("to_weight")
    assert_equal @published, @scorecard.reload.current_version

    version = HealthScorecardProposalWorkflow.accept!(
      workspace: @workspace, membership: @owner, proposal: revision, expected_proposal_id: revision.id
    )
    assert_equal revision, version.source_proposal
    assert_equal @owner.user, version.created_by_user
    assert_equal @published, @scorecard.reload.current_version
    assert_equal @prior_assessment.score, @account.health_assessments.order(:id).last.score

    assert_raises(HealthScorecardPublisher::InvalidPublish) do
      HealthScorecardPublisher.publish!(
        workspace: @workspace, membership: @owner, version:,
        expected_current_version_id: @scorecard.current_version_id, expected_backtest_id: nil
      )
    end

    backtest = HealthScorecardBacktester.run!(workspace: @workspace, membership: @owner, version:, at: @at)
    assert_equal 500, backtest.results.fetch("summary").fetch("snapshot_limit")
    published = HealthScorecardPublisher.publish!(
      workspace: @workspace, membership: @owner, version:,
      expected_current_version_id: @scorecard.current_version_id, expected_backtest_id: backtest.id
    )
    assert_equal version, published
    assert_equal version, @scorecard.reload.current_version

    later = AccountHealth.recalculate!(workspace: @workspace, account: @account,
      trigger_kind: "human_request", membership: @owner, at: @at + 1.hour)
    assert_equal version, later.health_scorecard_version
    assert_equal @published, @prior_assessment.reload.health_scorecard_version
    assert AuditEvent.exists?(action: "scorecard.published", subject_type: version.class.name, subject_id: version.id)
  end

  private
    def generate_proposal(prompt, parent_proposal: nil, expected_latest_proposal_id: nil)
      HealthScorecardProposalWorkflow.generate!(
        workspace: @workspace, membership: @owner, prompt:, parent_proposal:,
        expected_latest_proposal_id:, admit: false
      )
    end

    def complete_run(run, output)
      ledger = ExecutionLedger.new(workspace: @workspace)
      [
        [ 1, "run.admitted", { workspace_key: @workspace.runner_key, task_key: run.crew_task.task_key, attempt: run.attempt_number } ],
        [ 2, "run.started", { adapter: "scripted", scenario: "scorecard", attempt: run.attempt_number } ],
        [ 3, "output.produced", { text: output } ],
        [ 4, "run.completed", { outcome: "completed" } ]
      ].each do |sequence, type, data|
        ledger.ingest!(event: {
          "protocol_version" => "v1", "event_id" => SecureRandom.uuid, "run_id" => run.run_key,
          "sequence" => sequence, "event_type" => type,
          "occurred_at" => (Time.current.change(usec: 0) + sequence.seconds).iso8601(6),
          "data" => data.deep_stringify_keys
        })
      end
      @workspace.health_scorecard_proposals.find_by!(execution_run: run)
    end

    def proposal_output(renewal:, sla:, explanation:)
      JSON.generate(
        schema_version: 1, kind: "scorecard_proposal",
        definition: {
          "schema_version" => 1, "healthy_min" => 75, "watch_min" => 50,
          "rules" => [
            { "signal_key" => "renewal_on", "weight" => renewal },
            { "signal_key" => "sla_breaches", "weight" => sla }
          ]
        },
        explanation:, assumptions: [ "Only retained catalog signals can change the score." ],
        unsupported_requests: [], missing_evidence: []
      )
    end
end
