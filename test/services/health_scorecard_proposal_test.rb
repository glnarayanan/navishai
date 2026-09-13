require "test_helper"

class HealthScorecardProposalTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
    @scorecard = HealthScorecardDesigner.install_default!(workspace: @workspace)
    @published = @scorecard.current_version
    @account = @workspace.accounts.create!(name: "Scorecard Proposal Test")
    @at = Time.zone.parse("2026-08-24 12:00:00")
    AccountHealth.recalculate!(workspace: @workspace, account: @account,
      trigger_kind: "human_request", membership: @owner, at: @at)
  end

  test "maps a supported request through the scripted runtime without publishing or scoring" do
    approve_scripted_runtime(workspace: @workspace, membership: @owner)
    prior_score = @account.health_assessments.order(:id).last.score
    run = generate_proposal("Make approaching renewal and repeated SLA breaches matter more.")
    proposal = complete_run(run, valid_output)

    assert proposal.valid_status?
    assert_equal %w[renewal_on sla_breaches], proposal.proposed_definition.fetch("rules").pluck("signal_key")
    assert_equal 40, proposal.proposed_definition.fetch("rules").find { |rule| rule["signal_key"] == "renewal_on" }.fetch("weight")
    assert_equal 35, proposal.proposed_definition.fetch("rules").find { |rule| rule["signal_key"] == "sla_breaches" }.fetch("weight")
    assert_match(/renewal/i, proposal.explanation)
    assert_includes proposal.assumptions, "Only retained catalog signals can change the score."
    assert_equal "scripted", proposal.execution_run.selected_adapter_key
    assert_equal @published, @scorecard.reload.current_version
    assert_equal prior_score, @account.health_assessments.order(:id).last.score
    assert AuditEvent.exists?(action: "scorecard.proposal_generated", subject_type: proposal.class.name, subject_id: proposal.id)
    assert_nil @workspace.crew_artifacts.find_by(execution_run: run)

    version = HealthScorecardProposalWorkflow.accept!(workspace: @workspace, membership: @owner, proposal:)
    assert_equal 2, version.version_number
    assert_equal proposal, version.source_proposal
    assert_equal @published, @scorecard.reload.current_version
    assert_equal prior_score, @account.health_assessments.order(:id).last.score
    assert_raises(HealthScorecardProposalWorkflow::InvalidCommand) do
      HealthScorecardProposalWorkflow.accept!(workspace: @workspace, membership: @owner, proposal: proposal.reload)
    end
  end

  test "reports unsupported sentiment and refuses a churn-prediction claim" do
    approve_scripted_runtime(workspace: @workspace, membership: @owner)

    sentiment = complete_run(generate_proposal("Use sentiment from all calls."), unsupported_output)
    assert sentiment.unsupported_status?
    assert_nil sentiment.proposed_definition
    assert_match(/sentiment/i, sentiment.unsupported_requests.join)
    assert_raises(HealthScorecardProposalWorkflow::InvalidCommand) do
      HealthScorecardProposalWorkflow.accept!(workspace: @workspace, membership: @owner, proposal: sentiment)
    end

    churn = complete_run(generate_proposal("Optimize to predict churn."), churn_claim_output)
    assert churn.invalid_status?
    assert_match(/validated prediction/i, churn.validation_detail)
    assert_equal @published, @scorecard.reload.current_version
  end

  test "rejects malformed output, extra commands, canceled runs, budget overruns, and missing runtimes" do
    approve_scripted_runtime(workspace: @workspace, membership: @owner)
    malformed = complete_run(generate_proposal("Make approaching renewal matter more."), "{not json")
    assert malformed.invalid_status?

    extra = complete_run(generate_proposal("Make approaching renewal matter more."), sql_output)
    assert extra.invalid_status?
    assert_match(/SQL|code|commands/i, extra.validation_detail)

    canceled = generate_proposal("Make approaching renewal matter more.")
    cancel_run(canceled)
    assert canceled.reload.canceled?
    assert_not @workspace.health_scorecard_proposals.exists?(execution_run: canceled)

    budget = generate_proposal("Make approaching renewal matter more.")
    assert_raises(ExecutionLedger::EventConflict) { exceed_budget(budget) }

    runtime_installations(:acme_scripted).update!(
      approved: false, approved_by_membership: nil, approved_by_user: nil, approved_at: nil
    )
    assert_raises(HealthScorecardProposalWorkflow::InvalidCommand) do
      HealthScorecardProposalWorkflow.generate!(workspace: @workspace, membership: @owner,
        prompt: "Make approaching renewal matter more.", admit: false)
    end
  end

  test "revises a proposal with inspectable lineage and rejects stale tabs" do
    approve_scripted_runtime(workspace: @workspace, membership: @owner)
    parent = complete_run(generate_proposal("Make approaching renewal and repeated SLA breaches matter more."), valid_output)
    run = generate_proposal(
      "Raise SLA-breach weight further and keep renewal proximity.",
      parent_proposal: parent, expected_latest_proposal_id: parent.id
    )
    assert_equal "Revise a health scorecard proposal", run.crew_task.title
    assert_includes run.crew_task.input_context, "scorecard_proposal_revision"
    assert_includes run.crew_task.input_context, parent.execution_run.run_key
    revision = complete_run(run, revision_output)

    assert_equal parent, revision.parent_proposal
    sla = revision.proposed_definition.fetch("rules").find { |rule| rule["signal_key"] == "sla_breaches" }
    assert_equal 50, sla.fetch("weight")
    sla_change = revision.inspectable_diff(parent.proposed_definition).fetch("rules")
      .find { |rule| rule["signal_key"] == "sla_breaches" }
    assert_equal "changed", sla_change.fetch("kind")
    assert_equal 35, sla_change.fetch("from_weight")
    assert_equal 50, sla_change.fetch("to_weight")
    assert AuditEvent.exists?(action: "scorecard.proposal_generated", subject_type: revision.class.name, subject_id: revision.id)

    assert_raises(HealthScorecardProposalWorkflow::InvalidCommand) do
      generate_proposal("Raise SLA-breach weight further and keep renewal proximity.",
        parent_proposal: parent, expected_latest_proposal_id: parent.id)
    end
    assert_raises(HealthScorecardProposalWorkflow::InvalidCommand) do
      HealthScorecardProposalWorkflow.accept!(workspace: @workspace, membership: @owner, proposal: revision,
        expected_proposal_id: parent.id)
    end
    version = HealthScorecardProposalWorkflow.accept!(workspace: @workspace, membership: @owner, proposal: revision,
      expected_proposal_id: revision.id)
    assert_equal revision, version.source_proposal
    assert_equal @owner.user, version.created_by_user
    assert_equal @published, @scorecard.reload.current_version
  end

  test "fails closed for a foreign parent proposal" do
    approve_scripted_runtime(workspace: @workspace, membership: @owner)
    parent = complete_run(generate_proposal("Make approaching renewal and repeated SLA breaches matter more."), valid_output)
    assert_raises(ActiveRecord::RecordNotFound) do
      HealthScorecardProposalWorkflow.generate!(
        workspace: workspaces(:beta_support), membership: memberships(:outsider_beta),
        prompt: "Raise SLA-breach weight further and keep renewal proximity.",
        parent_proposal: parent, admit: false
      )
    end
  end

  test "diffs added removed and unchanged rules" do
    from = {
      "healthy_min" => 75, "watch_min" => 50,
      "rules" => [ { "signal_key" => "open_cases", "weight" => 20 }, { "signal_key" => "sla_breaches", "weight" => 25 } ]
    }
    to = {
      "healthy_min" => 80, "watch_min" => 50,
      "rules" => [ { "signal_key" => "sla_breaches", "weight" => 40 }, { "signal_key" => "renewal_on", "weight" => 30 } ]
    }
    diff = HealthScorecardProposalDiff.between(from, to)
    assert_equal [ 75, 80 ], diff.fetch("healthy_min")
    kinds = diff.fetch("rules").index_by { |rule| rule.fetch("signal_key") }
    assert_equal "removed", kinds.fetch("open_cases").fetch("kind")
    assert_equal "changed", kinds.fetch("sla_breaches").fetch("kind")
    assert_equal "added", kinds.fetch("renewal_on").fetch("kind")
  end

  test "keeps the manual designer and fails closed across Workspaces" do
    version = HealthScorecardDesigner.propose!(workspace: @workspace, membership: @owner,
      prompt: "Focus the score on unresolved support work.", healthy_min: 75, watch_min: 50,
      weights: { "open_cases" => 40 })
    assert_equal @published, @scorecard.reload.current_version
    assert_nil version.source_proposal

    approve_scripted_runtime(workspace: @workspace, membership: @owner)
    proposal = complete_run(generate_proposal("Make approaching renewal and repeated SLA breaches matter more."), valid_output)
    foreign = workspaces(:beta_support)
    assert_raises(ActiveRecord::RecordNotFound) do
      HealthScorecardProposalWorkflow.accept!(workspace: foreign, membership: memberships(:outsider_beta), proposal:)
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      HealthScorecardProposal.transaction(requires_new: true) do
        HealthScorecardProposal.where(id: proposal.id).update_all(explanation: "tampered")
      end
    end
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
      time = Time.current.change(usec: 0)
      ingest(ledger, run, 1, "run.admitted", workspace_key: @workspace.runner_key,
        task_key: run.crew_task.task_key, attempt: run.attempt_number)
      ingest(ledger, run, 2, "run.started", adapter: "scripted", scenario: "scorecard", attempt: run.attempt_number)
      ingest(ledger, run, 3, "output.produced", text: output)
      ingest(ledger, run, 4, "run.completed", outcome: "completed")
      @workspace.health_scorecard_proposals.find_by!(execution_run: run)
    end

    def cancel_run(run)
      ledger = ExecutionLedger.new(workspace: @workspace)
      ingest(ledger, run, 1, "run.admitted", workspace_key: @workspace.runner_key,
        task_key: run.crew_task.task_key, attempt: run.attempt_number)
      ingest(ledger, run, 2, "run.started", adapter: "scripted", scenario: "scorecard", attempt: run.attempt_number)
      ingest(ledger, run, 3, "run.canceled", reason: "operator_canceled")
    end

    def exceed_budget(run)
      ledger = ExecutionLedger.new(workspace: @workspace)
      ingest(ledger, run, 1, "run.admitted", workspace_key: @workspace.runner_key,
        task_key: run.crew_task.task_key, attempt: run.attempt_number)
      ingest(ledger, run, 2, "run.started", adapter: "scripted", scenario: "scorecard", attempt: run.attempt_number)
      ingest(ledger, run, 3, "usage.observed", input_units: run.max_input_units + 1, output_units: 1)
    end

    def ingest(ledger, run, sequence, type, **data)
      ledger.ingest!(event: {
        "protocol_version" => "v1",
        "event_id" => SecureRandom.uuid,
        "run_id" => run.run_key,
        "sequence" => sequence,
        "event_type" => type,
        "occurred_at" => (Time.current.change(usec: 0) + sequence.seconds).iso8601(6),
        "data" => data.deep_stringify_keys
      })
    end

    def valid_output
      proposal_json(
        rules: [
          { "signal_key" => "renewal_on", "weight" => 40 },
          { "signal_key" => "sla_breaches", "weight" => 35 }
        ],
        explanation: "I increased renewal proximity and SLA breach weights using only catalog signals. This does not calculate account scores."
      )
    end

    def revision_output
      proposal_json(
        rules: [
          { "signal_key" => "renewal_on", "weight" => 40 },
          { "signal_key" => "sla_breaches", "weight" => 50 }
        ],
        explanation: "I raised the SLA-breach weight further and kept renewal proximity. This does not calculate account scores."
      )
    end

    def proposal_json(rules:, explanation:)
      JSON.generate(
        schema_version: 1, kind: "scorecard_proposal",
        definition: { "schema_version" => 1, "healthy_min" => 75, "watch_min" => 50, "rules" => rules },
        explanation:, assumptions: [ "Only retained catalog signals can change the score." ],
        unsupported_requests: [], missing_evidence: []
      )
    end

    def unsupported_output
      JSON.generate(
        schema_version: 1, kind: "scorecard_proposal", definition: nil,
        explanation: "Call sentiment is not a retained scorecard signal, so no definition was proposed.",
        assumptions: [ "Scoring uses only catalogued retained facts." ],
        unsupported_requests: [ "Sentiment from customer calls is not a supported scorecard signal." ],
        missing_evidence: [ "No retained call-sentiment signal exists in this Workspace." ]
      )
    end

    def churn_claim_output
      JSON.generate(
        schema_version: 1, kind: "scorecard_proposal",
        definition: {
          "schema_version" => 1, "healthy_min" => 75, "watch_min" => 50,
          "rules" => [ { "signal_key" => "renewal_on", "weight" => 40 } ]
        },
        explanation: "This validated prediction of churn uses renewal timing as a proxy.",
        assumptions: [],
        unsupported_requests: [],
        missing_evidence: []
      )
    end

    def sql_output
      JSON.generate(
        schema_version: 1, kind: "scorecard_proposal", definition: nil,
        explanation: "SELECT weight FROM health_signals; DROP TABLE accounts;",
        assumptions: [],
        unsupported_requests: [],
        missing_evidence: []
      )
    end
end
