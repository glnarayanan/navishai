module HumanDraftTestHelper
  def create_draft_artifact(workspace:, support_case:, membership:, body: "Generated answer",
    artifact_kind: "draft", result_state: "complete", evidence_status: "available",
    claim_state: nil, contract_blockers: nil, blocker_message: "Material claim reset policy is stale.",
    remediation: "Refresh the cited source and run the specialist again.")
    install_crew_test_dependencies(workspace:, membership:)
    role_key = artifact_kind == "draft" ? "resolution_drafter" : "support_investigator"
    profile = workspace.agent_profiles.find_by!(role_key:)
    task = CrewWork.create!(
      workspace:, membership:, scope: support_case, profile:,
      title: "#{artifact_kind.humanize} source #{SecureRandom.hex(4)}",
      input_context: "Use the current Support case.",
      expected_output: "Return a typed #{artifact_kind.humanize.downcase}."
    )
    run = ExecutionLedger.new(workspace:).prepare!(
      task:, request_key: "human-draft-test:#{SecureRandom.uuid}"
    )
    message = support_case.conversation.conversation_messages.inbound.order(:occurred_at, :id).last ||
      add_inbound_message(support_case)
    locator = "conversation://#{support_case.conversation_id}/messages/#{message.id}"
    evaluated_claim_state = claim_state || (result_state == "complete" ? "supported" : "uncertain")
    evidence = {
      "kind" => "conversation", "locator" => locator, "status" => evidence_status,
      "observed_at" => message.occurred_at.iso8601(6), "valid_until" => nil,
      "fresh_until" => (message.occurred_at + 365.days).iso8601(6)
    }
    available_evidence = evidence.merge("status" => "available")
    blockers = contract_blockers
    if blockers.nil?
      blockers = if result_state == "complete"
        []
      else
        [ {
          "code" => "claim_#{evidence_status == 'available' ? evaluated_claim_state : evidence_status}",
          "claim_key" => "reset_policy", "message" => blocker_message,
          "remediation" => remediation, "severity" => result_state == "blocked" ? "blocking" : "review"
        } ]
      end
    end
    contract = workspace.resolution_contract_families.find_by!(family_key: "support_resolution").current_version

    workspace.crew_artifacts.create!(
      crew_task: task, execution_run: run, version_number: 1, schema_version: 2,
      artifact_kind:, body:, uncertainty: "The customer has not confirmed the outcome.",
      citations: [ { "kind" => "conversation", "locator" => locator, "label" => "Customer report" } ],
      conflicts: [], change_requests: [], payload_digest: Digest::SHA256.hexdigest(SecureRandom.uuid),
      resolution_contract_version: contract,
      required_facts: %w[customer_report reset_policy],
      material_claims: [
        {
          "key" => "customer_report", "category" => "customer_account_fact",
          "text" => "The customer requested help.", "state" => "supported", "evidence" => [ available_evidence ]
        },
        {
          "key" => "reset_policy", "category" => "product_technical_fact",
          "text" => "A new reset link is required.", "state" => evaluated_claim_state, "evidence" => [ evidence ]
        }
      ],
      proposed_actions: [],
      policy_checks: ResolutionContractVersion::REVIEW_CHECKS.keys.sort.map do |check|
        status = result_state == "complete" || check == "human_authority_preserved" ? "passed" : "failed"
        { "check" => check, "status" => status }
      end,
      contract_result_state: result_state, contract_blockers: blockers,
      contract_evaluated_at: Time.current
    )
  end
end
