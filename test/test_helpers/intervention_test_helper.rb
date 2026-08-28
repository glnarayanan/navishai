module InterventionTestHelper
  def create_reviewed_intervention_plan(workspace:, account:, membership:, assessment: nil,
    review_outcome: "approved", plan_result: "complete", review_result: "complete")
    assessment ||= account.current_health_assessment || AccountHealth.recalculate!(
      workspace:, account:, trigger_kind: "human_request", membership:
    )
    plan = create_intervention_artifact(
      workspace:, account:, membership:, assessment:, kind: "intervention_plan", result: plan_result
    )
    review = create_intervention_artifact(
      workspace:, account:, membership:, assessment:, kind: "success_review",
      result: review_result, target: plan, review_outcome:
    )
    [ plan, review ]
  end

  def create_intervention_artifact(workspace:, account:, membership:, assessment:, kind:,
    result: "complete", target: nil, review_outcome: nil, supersedes: nil)
    install_crew_test_dependencies(workspace:, membership:)
    role_key = {
      "intervention_plan" => "success_strategist",
      "success_review" => "success_reviewer",
      "risk_investigation" => "risk_investigator"
    }.fetch(kind)
    task = supersedes&.crew_task || begin
      profile = workspace.agent_profiles.find_by!(role_key:)
      CrewWork.create!(
        workspace:, membership:, scope: account, profile:,
        title: "#{kind.humanize} #{SecureRandom.hex(4)}",
        input_context: "Use the current deterministic Account health record.",
        expected_output: "Return a cited #{kind.humanize.downcase}."
      )
    end
    run = ExecutionLedger.new(workspace:).prepare!(
      task:, request_key: "intervention-test:#{SecureRandom.uuid}"
    )
    signal = assessment.signals.first
    citation = {
      "kind" => "health_signal", "locator" => signal.citation_uri,
      "label" => "Deterministic health signal"
    }
    evidence = citation.except("label").merge(
      "status" => "available", "observed_at" => assessment.calculated_at.iso8601(6),
      "valid_until" => nil, "fresh_until" => (assessment.calculated_at + 14.days).iso8601(6)
    )
    contract = workspace.resolution_contract_families
      .find_by!(family_key: "customer_success_intervention").current_version
    blockers = result == "complete" ? [] : [ {
      "code" => "claim_uncertain", "claim_key" => "observable_change",
      "message" => "The proposed outcome is not fully supported.",
      "remediation" => "Review a current deterministic health signal.", "severity" => "blocking"
    } ]

    workspace.crew_artifacts.create!(
      crew_task: task, execution_run: run,
      version_number: supersedes&.version_number.to_i + 1, supersedes_artifact: supersedes,
      schema_version: 2, artifact_kind: kind, target_artifact: target,
      review_outcome: kind == "success_review" ? review_outcome : nil,
      body: kind == "success_review" ? "A human can own this bounded intervention." :
        "Review adoption and usage with the Account team.",
      uncertainty: "The later observed outcome remains unknown.", citations: [ citation ],
      conflicts: [], change_requests: [], payload_digest: Digest::SHA256.hexdigest(SecureRandom.uuid),
      resolution_contract_version: contract,
      required_facts: %w[account_health observable_change],
      material_claims: [
        {
          "key" => "account_health", "category" => "customer_account_fact",
          "text" => "Current Account health is recorded.",
          "state" => "supported", "evidence" => [ evidence ]
        },
        {
          "key" => "observable_change", "category" => "promised_action_date",
          "text" => "A human will choose any action and follow-up date.",
          "state" => result == "complete" ? "supported" : "uncertain",
          "evidence" => [ evidence ]
        }
      ],
      proposed_actions: [],
      policy_checks: ResolutionContractVersion::REVIEW_CHECKS.keys.sort.map do |check|
        { "check" => check, "status" => result == "complete" ? "passed" : "failed" }
      end,
      contract_result_state: result, contract_blockers: blockers,
      contract_evaluated_at: Time.current
    )
  end

  def propose_test_intervention(workspace:, account:, membership:, assessment:, artifact:,
    accountable_membership: membership, investigation: nil, at: Time.current)
    CustomerSuccessInterventionWorkflow.propose!(
      workspace:, membership:, account:, assessment:, artifact:, investigation:,
      accountable_membership:, expected_observable_change: "Increase deterministic Account health evidence.",
      target_on: at.to_date + 7.days, reason: "A human accepted this reviewed plan for a measured follow-up.", at:
    )
  end
end
