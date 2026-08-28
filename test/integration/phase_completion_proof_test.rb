require "test_helper"

class PhaseCompletionProofTest < ActiveSupport::TestCase
  class RecordingTransport
    attr_reader :deliveries

    def initialize
      @deliveries = []
    end

    def deliver!(**attributes)
      deliveries << attributes
      true
    end
  end

  EmptyIntercomClient = Struct.new(:requests) do
    def conversations(starting_after: nil)
      requests << [ :conversations, starting_after ]
      { "conversations" => [], "pages" => { "next" => nil } }
    end

    %i[add_note reply assign tag untag create_tag].each do |method_name|
      define_method(method_name) { |**| raise "remote mutation attempted: #{method_name}" }
    end
  end

  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
    @account = accounts(:acme)
    @now = Time.zone.parse("2026-08-28 12:00:00 UTC")
    Current.session = @owner.user.sessions.create!(authentication_method: :local, expires_at: 12.hours.from_now)
  end

  test "Support proof, explanation, dossier, health intervention, and governed rollback remain one lineage" do
    support_case = receive_support_case
    support_case.conversation.contact.update!(account: @account)
    blocked = create_draft_artifact(
      workspace: @workspace, support_case:, membership: @owner,
      body: "The legacy policy guarantees access today.", result_state: "blocked",
      evidence_status: "stale", claim_state: "conflicted",
      blocker_message: "The retained policy conflicts with the current customer report.",
      remediation: "Use the current report and qualify the answer."
    )
    corrected = create_draft_artifact(
      workspace: @workspace, support_case:, membership: @owner,
      body: "The current report confirms the fault; timing remains unconfirmed."
    )
    quality_review = create_quality_review(support_case, corrected)
    memory = create_corrected_memory
    corrected.execution_run.execution_memory_selections.create!(
      workspace: @workspace, memory_record: memory, rank: 1, relevance_score: 0.95
    )

    draft = EmailDraftWorkflow.save!(
      workspace: @workspace, support_case:, membership: @owner,
      body: corrected.body, expected_lock_version: "new",
      source_crew_artifact_id: corrected.id, adopt_source: true
    )
    final_body = "We confirmed the access fault. Timing remains unconfirmed while we check the current policy."
    draft = EmailDraftWorkflow.save!(
      workspace: @workspace, support_case:, membership: @owner,
      body: final_body, expected_lock_version: draft.lock_version.to_s,
      source_crew_artifact_id: corrected.id
    )
    preview = HumanEmailSend.recipient_preview(workspace: @workspace, support_case:)
    transport = RecordingTransport.new
    delivery = HumanEmailSend.send!(
      workspace: @workspace, support_case:, membership: @owner, body: final_body,
      draft_version: draft.lock_version.to_s, idempotency_key: "m6-human-send",
      source_crew_artifact_id: corrected.id, expected_recipient_address: preview.address,
      expected_inbound_message_id: preview.inbound_message_id, transport:
    )

    assert blocked.contract_blocking?
    assert_equal "approved", quality_review.review_outcome
    assert delivery.sent?
    assert_equal @owner, delivery.human_edited_by_membership
    assert_equal final_body, transport.deliveries.sole.fetch(:body)

    explanation = OutcomeExplanation.resolve!(
      workspace: @workspace, membership: @owner, subject_type: "case", subject_id: support_case.id
    )
    assert_includes explanation.artifacts, blocked
    assert_includes explanation.artifacts, corrected
    assert_includes explanation.reviews, quality_review
    assert_includes explanation.memory_selections.map(&:memory_record), memory
    assert_equal delivery, explanation.final_delivery
    assert_equal "Stale", explanation.freshness
    assert_equal "No further action is recorded.", explanation.next_action

    recurring_case = create_support_case(
      subject: "Access fault returned", workspace: @workspace,
      contact: support_case.conversation.contact, membership: @owner
    )
    tag = CaseWorkflow.create_tag!(workspace: @workspace, membership: @owner, name: "Recurring access")
    [ support_case, recurring_case ].each do |record|
      CaseWorkflow.tag!(workspace: @workspace, support_case: record, membership: @owner, tag:)
    end
    next_task = CrewWork.create!(
      workspace: @workspace, membership: @owner, scope: recurring_case,
      profile: @workspace.agent_profiles.find_by!(role_key: "support_investigator"),
      title: "Confirm the current access policy", input_context: "Use current retained evidence.",
      expected_output: "Answer the unresolved policy question."
    )
    assessment = AccountHealth.recalculate!(
      workspace: @workspace, account: @account, trigger_kind: "human_request",
      membership: @owner, at: @now
    )
    dossier = AccountDossier.new(
      workspace: @workspace, account: @account, membership: @owner, now: @now
    )
    assert_includes dossier.recurring_issues.map(&:name), "Recurring access"
    assert dossier.memory_groups.find { |group| group.label == "support-hours" }.conflicted
    assert_equal assessment.risk_investigation, dossier.next_action.record
    assert next_task.ready?
    assert_equal assessment, dossier.assessment

    plan, = create_reviewed_intervention_plan(
      workspace: @workspace, account: @account, membership: @owner, assessment:
    )
    intervention = propose_test_intervention(
      workspace: @workspace, account: @account, membership: @owner,
      assessment:, artifact: plan, investigation: assessment.risk_investigation, at: @now + 1.minute
    )
    CustomerSuccessInterventionWorkflow.approve!(
      workspace: @workspace, membership: @owner, intervention:, at: @now + 2.minutes
    )
    CustomerSuccessInterventionWorkflow.complete!(
      workspace: @workspace, membership: @owner, intervention:, at: @now + 3.minutes
    )
    after_assessment = AccountHealth.recalculate!(
      workspace: @workspace, account: @account, trigger_kind: "human_request",
      membership: @owner, at: @now + 4.minutes
    )
    outcome_review = CustomerSuccessInterventionWorkflow.review!(
      workspace: @workspace, membership: @owner, intervention:, after_assessment:,
      uncertainty: "The observed change does not establish cause.", at: @now + 5.minutes
    )
    assert intervention.reload.reviewed?
    assert_equal assessment.id, outcome_review.before_snapshot.fetch("assessment_id")
    assert_equal after_assessment.id, outcome_review.after_snapshot.fetch("assessment_id")
    assert_includes outcome_review.observed_association, "does not assign cause"

    proposal, policy_preview, canary = create_governed_policy_canary(
      workspace: @workspace, membership: @owner, support_case: recurring_case
    )
    canary_task = CrewWork.create!(
      workspace: @workspace, membership: @owner, scope: recurring_case,
      profile: @workspace.agent_profiles.find_by!(role_key: "support_investigator"),
      title: "Canary policy task", input_context: "Use retained facts.",
      expected_output: "Return the bounded result."
    )
    rollback = GovernedPolicyChange.rollback!(
      workspace: @workspace, membership: @owner, publication: canary,
      expected_publication_id: canary.id, reason: "M6 canary proof complete"
    )
    future_task = CrewWork.create!(
      workspace: @workspace, membership: @owner, scope: recurring_case,
      profile: @workspace.agent_profiles.find_by!(role_key: "support_investigator"),
      title: "Future rollback task", input_context: "Use retained facts.",
      expected_output: "Return the bounded result."
    )
    assert policy_preview.results.any? { |result| result.fetch("changes").present? }
    assert_equal canary, canary_task.governed_policy_publication
    assert_equal rollback, future_task.governed_policy_publication
    assert_equal canary.resolution_contract_version, canary_task.reload.resolution_contract_version
    assert_equal proposal.prior_resolution_contract_version, future_task.resolution_contract_version
  end

  test "reliability faults expose only safe recovery paths" do
    inbox = @workspace.shared_email_inboxes.create!(
      name: "Stale M6 connector", email_address: "m6-stale@example.com", credential_key: "m6_stale"
    )
    inbox.inbound_email_deliveries.create!(
      workspace: @workspace, source_message_id: "m6-stale@example.com",
      content_sha256: Digest::SHA256.hexdigest("stale"), raw_email: "stale",
      status: :failed, failure_code: "missing_sender", received_at: @now - 2.days,
      processed_at: @now - 2.days
    )
    runtime = runtime_installations(:acme_scripted)
    runtime.update!(health_status: "unhealthy", checked_at: @now)
    memory = @workspace.memory_records.create!(
      memory_type: :semantic, scope_kind: :workspace, topic: "m6-recovery",
      content: "Rebuild this index from PostgreSQL.", authority: :source_record,
      origin_kind: :system, source_reference: "test://m6-recovery",
      source_digest: Digest::SHA256.hexdigest("m6-recovery"), observed_at: @now - 1.day,
      valid_from: @now - 1.day, confidence: 1, retention_policy: :indefinite
    )
    @workspace.memory_index_entries.create!(
      memory_record: memory, status: :failed, attempt_count: 1,
      failure_code: "remote_unavailable", last_attempted_at: @now - 10.minutes
    )
    unknown = create_unknown_delivery
    OperationalCheck.record!(
      workspace: @workspace, membership: @owner, check_kind: "backup_verification",
      result: "failed", result_code: "checksum_mismatch",
      evidence_digest: Digest::SHA256.hexdigest("m6-backup-failure"), source_commit: "a" * 40,
      checked_at: @now - 1.hour
    )

    cockpit = ReliabilityCockpit.build(
      workspace: @workspace, membership: @owner, now: @now,
      queue_snapshot: { status: "healthy", ready_count: 0, overdue_count: 0, failed_count: 0,
        oldest_ready_at: nil, last_heartbeat_at: @now }
    )
    groups = cockpit.groups.index_by(&:key)
    assert_equal "blocked", groups.fetch("connectors").status
    assert_equal "blocked", groups.fetch("execution").status
    assert_equal "blocked", groups.fetch("memory").status
    assert_equal "blocked", groups.fetch("data").status
    send_item = groups.fetch("sends").items.find { |item| item.record == unknown }
    assert_equal "unknown", send_item.status
    assert_equal "review_email_send", send_item.action
    assert_equal "manage_runtime",
      groups.fetch("execution").items.find { |item| item.record == runtime }.action
    assert_equal 1, ReliabilityRecovery.reconstruct_memory!(workspace: @workspace, membership: @owner)
    assert @workspace.memory_index_entries.find_by!(memory_record: memory).indexing?
    assert unknown.reload.unknown?
  end

  test "read-only backfill, archive round trip, and Memory reconstruction preserve authority" do
    connection = @workspace.intercom_connections.create!(
      name: "M6 historical", remote_workspace_id: "m6-history", credential_key: "m6_history"
    )
    client = EmptyIntercomClient.new([])
    manifest = IntercomHistoricalBackfill.preview!(
      connection:, membership: @owner, client:, discovered_at: @now
    )
    run = IntercomHistoricalBackfill.confirm!(
      connection:, manifest:, membership: @owner, client:, enqueue: false
    )
    IntercomHistoricalBackfill.perform!(run:, client:)
    report = run.reload.intercom_backfill_report

    assert run.completed?
    assert report.complete?
    assert report.reconciled?
    assert_equal IntercomHistoricalBackfill::COUNT_KEYS.index_with { 0 }, report.counts
    assert_equal [ [ :conversations, nil ], [ :conversations, nil ] ], client.requests

    source_memory = @workspace.memory_records.create!(
      memory_type: :semantic, scope_kind: :workspace, topic: "m6-portability",
      content: "PostgreSQL remains authoritative after restore.", authority: :source_record,
      origin_kind: :system, source_reference: "test://m6-portability",
      source_digest: Digest::SHA256.hexdigest("m6-portability"), observed_at: @now,
      valid_from: @now, confidence: 1, retention_policy: :indefinite
    )
    @workspace.memory_index_entries.create!(
      memory_record: source_memory, status: :indexed, attempt_count: 1,
      external_document_id: "must-not-cross-archive", external_status: "done",
      last_attempted_at: @now, indexed_at: @now
    )
    verification = WorkspacePortability.verify_round_trip(
      workspace: @workspace, membership: @owner, name: "M6 verified restore",
      slug: "m6-verified-restore", source_commit: "b" * 40, checked_at: @now
    )
    restored = verification.workspace
    restored_memory = restored.memory_records.find_by!(topic: "m6-portability")

    assert_equal "passed", verification.operational_check.result
    assert_equal source_memory.content, restored_memory.content
    assert restored.memory_index_entries.find_by!(memory_record: restored_memory).indexing?
    assert_nil restored.memory_index_entries.find_by!(memory_record: restored_memory).external_document_id
    assert restored.intercom_backfill_reports.sole.reconciled?
  end

  private
    def receive_support_case
      inbox = @workspace.shared_email_inboxes.create!(
        name: "M6 Support", email_address: "m6-support@example.com", credential_key: "m6_support"
      )
      raw_email = [
        "From: Alice Example <alice@example.net>", "To: M6 Support <m6-support@example.com>",
        "Date: Fri, 28 Aug 2026 11:55:00 +0000", "Subject: Access policy conflict",
        "Message-ID: <m6-root@example.net>", "MIME-Version: 1.0",
        "Content-Type: text/plain; charset=UTF-8", "",
        "The retained support hours conflict with the current access policy."
      ].join("\r\n")
      SharedEmailIntake.receive!(inbox:, raw_email:, received_at: @now).conversation.support_case
    end

    def create_quality_review(support_case, target)
      profile = @workspace.agent_profiles.find_by!(role_key: "support_reviewer")
      task = CrewWork.create!(
        workspace: @workspace, membership: @owner, scope: support_case, profile:,
        title: "Review the qualified result", input_context: "Review current proof.",
        expected_output: "Approve only a grounded result."
      )
      run = ExecutionLedger.new(workspace: @workspace).prepare!(task:, request_key: "m6-quality-review")
      @workspace.crew_artifacts.create!(
        crew_task: task, execution_run: run, version_number: 1, schema_version: 2,
        artifact_kind: "quality_review", target_artifact: target, review_outcome: "approved",
        body: "The qualified result matches current evidence and preserves human send authority.",
        uncertainty: "The timing remains explicitly unconfirmed.", citations: target.citations,
        conflicts: [], change_requests: [], payload_digest: Digest::SHA256.hexdigest("m6-quality-review"),
        resolution_contract_version: run.resolution_contract_version,
        required_facts: target.required_facts, material_claims: target.material_claims,
        proposed_actions: [], policy_checks: target.policy_checks,
        contract_result_state: "complete", contract_blockers: [], contract_evaluated_at: @now
      )
    end

    def create_corrected_memory
      source = @workspace.memory_records.create!(
        memory_type: :profile, scope_kind: :account, account: @account, topic: "support-hours",
        content: "Support ends at 17:00 UTC.", authority: :source_record, origin_kind: :system,
        source_reference: "test://m6/support-hours/source",
        source_digest: Digest::SHA256.hexdigest("17:00"), observed_at: @now - 2.days,
        valid_from: @now - 2.days, confidence: 0.8, retention_policy: :indefinite
      )
      @workspace.memory_records.create!(
        memory_type: :profile, scope_kind: :account, account: @account, topic: "support-hours",
        content: "Support may end at 19:00 UTC.", authority: :source_record, origin_kind: :system,
        source_reference: "test://m6/support-hours/conflict",
        source_digest: Digest::SHA256.hexdigest("19:00"), observed_at: @now - 1.day,
        valid_from: @now - 1.day, confidence: 0.7, retention_policy: :indefinite
      )
      MemoryGovernance.propose_correction!(
        workspace: @workspace, membership: @owner, memory_record: source,
        content: "Support ends at 18:00 UTC.", confidence: 1,
        retention_policy: :indefinite, proposed_at: @now - 1.hour
      ).published_memory_record
    end

    def create_unknown_delivery
      support_case = create_support_case(workspace: @workspace, membership: @owner)
      inbox = @workspace.shared_email_inboxes.create!(
        name: "M6 unknown send", email_address: "m6-unknown@example.com", credential_key: "m6_unknown"
      )
      thread = @workspace.email_threads.create!(
        shared_email_inbox: inbox, conversation: support_case.conversation,
        thread_key: "m6-unknown-thread"
      )
      draft = @workspace.email_drafts.create!(
        support_case:, email_thread: thread, conversation: support_case.conversation,
        updated_by: @owner.user, body: "Unknown external result", status: :sending
      )
      @workspace.outbound_email_deliveries.create!(
        email_draft: draft, shared_email_inbox: inbox, email_thread: thread,
        conversation: support_case.conversation, actor_membership: @owner, actor_user: @owner.user,
        idempotency_key: "m6-unknown-send", message_id: "m6-unknown@navishai.local",
        from_address: inbox.email_address, to_address: "customer@example.net", subject: "Reply",
        body: draft.body, status: :unknown, failure_code: "unknown_outcome", started_at: @now
      )
    end
end
