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

  ReadOnlyIntercomClient = Struct.new(:remotes, :requests) do
    def conversations(starting_after: nil)
      requests << [ :conversations, starting_after ]
      {
        "conversations" => remotes.values.map { |remote| { "id" => remote.fetch("id") } },
        "pages" => { "next" => nil }
      }
    end

    def conversation(id)
      requests << [ :conversation, id ]
      Marshal.load(Marshal.dump(remotes.fetch(id)))
    end

    def admins = { "admins" => [] }
    def teams = { "teams" => [] }

    %i[add_note reply assign tag untag create_tag].each do |method_name|
      define_method(method_name) { |**| raise "remote mutation attempted: #{method_name}" }
    end
  end

  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
    @account = accounts(:acme)
    @now = Time.current.change(usec: 0)
    Current.session = @owner.user.sessions.create!(authentication_method: :local, expires_at: 12.hours.from_now)
  end

  test "Support proof, explanation, dossier, health intervention, and governed rollback remain one lineage" do
    support_case = receive_support_case
    support_case.conversation.contact.update!(account: @account)
    stale_policy = create_policy_source("stale", retrieved_at: @now - 60.days)
    current_policy = create_policy_source("current", retrieved_at: @now)
    blocked = publish_draft_artifact(
      support_case:, body: "The legacy policy guarantees access today.",
      citation: knowledge_citation(stale_policy)
    )
    corrected = publish_draft_artifact(
      support_case:, body: "The current report confirms the fault; timing remains unconfirmed.",
      citation: knowledge_citation(current_policy), usage: { input_units: 120, output_units: 45 }
    )
    quality_review = create_quality_review(support_case, corrected)
    failed_run = create_failed_run(support_case, code: "stale_evidence")
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
    assert_equal "complete", corrected.contract_result_state
    assert_equal Digest::SHA256.hexdigest(blocked.execution_run.output), blocked.payload_digest
    assert_equal Digest::SHA256.hexdigest(corrected.execution_run.output), corrected.payload_digest
    assert_equal "approved", quality_review.review_outcome
    assert_equal corrected, quality_review.target_artifact
    assert_equal corrected, quality_review.execution_run.input_artifact
    assert quality_review.crew_task.reload.completed?
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
    assert_equal corrected.resolution_contract_version, corrected.execution_run.resolution_contract_version
    assert_equal %w[customer_report reset_policy], corrected.required_facts
    assert corrected.material_claims.all? { |claim| claim.fetch("evidence").present? }
    assert_equal "scripted", corrected.execution_run.selected_adapter_key
    assert_equal runtime_installations(:acme_scripted), corrected.execution_run.runtime_installation
    assert_equal 120, explanation.usage.input_units
    assert_equal 45, explanation.usage.output_units
    assert_equal "partial", explanation.usage.run_state
    assert_equal "stale_evidence", failed_run.failure_code
    assert explanation.blockers.any? { |item| item.fetch("code") == "claim_stale" }
    assert explanation.blockers.any? { |item| item.fetch("code") == "stale_evidence" }
    assert_equal @owner, delivery.human_edited_by_membership

    resolve_case(support_case)
    assert support_case.reload.status_resolved?

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
    support_hours = dossier.memory_groups.find { |group| group.label == "support-hours" }
    assert_includes dossier.recurring_issues.map(&:name), "Recurring access"
    assert_includes dossier.recent_cases, support_case
    assert support_case.status_resolved?
    assert support_hours.conflicted
    assert_equal "Support ends at 18:00 UTC.", support_hours.effective.content
    assert support_hours.items.any? { |item| item.state == "superseded" }
    assert_equal assessment.risk_investigation, dossier.next_action.record
    assert next_task.ready?
    assert_equal "Answer the unresolved policy question.", next_task.expected_output
    assert_equal assessment, dossier.assessment
    assert dossier.assessment.signals.any?

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
    assert plan.citations.any? { |citation| citation.fetch("kind") == "health_signal" }
    assert intervention.reload.reviewed?
    assert_equal @owner, intervention.approved_by_membership
    assert_equal @owner, intervention.completed_by_membership
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
    outside_case = create_support_case(
      subject: "Outside the policy canary", workspace: @workspace, membership: @owner
    )
    outside_task = CrewWork.create!(
      workspace: @workspace, membership: @owner, scope: outside_case,
      profile: @workspace.agent_profiles.find_by!(role_key: "support_investigator"),
      title: "Outside-scope task", input_context: "Use the published default.",
      expected_output: "Remain outside the canary."
    )
    frozen_canary_contract_id = canary_task.resolution_contract_version_id
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
    assert_nil outside_task.governed_policy_publication
    assert_equal rollback, future_task.governed_policy_publication
    assert_equal canary.resolution_contract_version, canary_task.reload.resolution_contract_version
    assert_equal frozen_canary_contract_id, canary_task.resolution_contract_version_id
    assert_equal canary, canary_task.governed_policy_publication
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
    runner_failure = create_retryable_runner_failure
    runtime = @workspace.runtime_installations.create!(
      detection_key: Digest::SHA256.hexdigest("m6-unhealthy-runtime"), adapter_key: "m6_unhealthy",
      protocol_version: "v1", executable_path: "/opt/navishai/m6-unhealthy",
      executable_version: "1", account_metadata: {}, capabilities: [],
      minimum_version: "1", maximum_version: "1", compatibility_status: "compatible",
      incompatibility_reason: "", health_status: "unhealthy", checked_at: @now
    )
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

    cockpit = ReliabilityCockpit.build(workspace: @workspace, membership: @owner, now: @now)
    groups = cockpit.groups.index_by(&:key)
    assert_equal "blocked", groups.fetch("connectors").status
    assert_equal "blocked", groups.fetch("execution").status
    assert_equal "blocked", groups.fetch("memory").status
    assert_equal "blocked", groups.fetch("data").status
    send_item = groups.fetch("sends").items.find { |item| item.record == unknown }
    connector_item = groups.fetch("connectors").items.find { |item| item.record == inbox }
    runtime_item = groups.fetch("execution").items.find { |item| item.record == runtime }
    runner_item = groups.fetch("execution").items.find { |item| item.record == runner_failure }
    memory_overview = groups.fetch("memory").items.find { |item| item.key == "memory-index" }
    memory_fault = groups.fetch("memory").items.find { |item| item.record == memory.memory_index_entry }
    backup_item = groups.fetch("data").items.find { |item| item.key == "backup_verification" }
    assert_equal "manage_email", connector_item.action
    assert_equal "manage_runtime", runtime_item.action
    assert_equal "retry_run", runner_item.action
    assert_equal "unknown", send_item.status
    assert_equal "review_email_send", send_item.action
    assert_match(/Do not resend/, send_item.summary)
    refute_equal "retry_run", send_item.action
    assert_equal "reconstruct_memory", memory_overview.action
    assert_nil memory_fault.action
    assert_nil backup_item.action
    assert_equal 1, ReliabilityRecovery.reconstruct_memory!(workspace: @workspace, membership: @owner)
    assert @workspace.memory_index_entries.find_by!(memory_record: memory).indexing?
    assert unknown.reload.unknown?
  end

  test "read-only backfill, archive round trip, and Memory reconstruction preserve authority" do
    connection = @workspace.intercom_connections.create!(
      name: "M6 historical", remote_workspace_id: "m6-history", credential_key: "m6_history"
    )
    client = ReadOnlyIntercomClient.new({ "m6-history-1" => historical_conversation }, [])
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
    assert_equal 1, report.counts.fetch("discovered")
    assert_equal 1, report.counts.fetch("imported")
    assert_equal 0, report.counts.fetch("pending")
    assert @workspace.intercom_conversation_links.exists?(remote_conversation_id: "m6-history-1")
    assert client.requests.all? { |kind, _| %i[conversations conversation].include?(kind) }

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
    restored_report = restored.intercom_backfill_reports.find_by!(report_digest: report.report_digest)
    assert_equal report.counts, restored_report.counts
    assert restored_report.reconciled?
    assert restored.intercom_conversation_links.exists?(remote_conversation_id: "m6-history-1")
  end

  private
    def ingest_run_event(run, sequence, event_type, data, occurred_at: nil)
      ExecutionLedger.new(workspace: @workspace).ingest!(event: {
        "protocol_version" => RunnerProtocol::VERSION,
        "event_id" => SecureRandom.uuid,
        "run_id" => run.run_key,
        "sequence" => sequence,
        "event_type" => event_type,
        "occurred_at" => (occurred_at || Time.current.change(usec: 0) + (sequence / 1_000.0).seconds).iso8601(6),
        "data" => data.stringify_keys
      })
    end

    def begin_run(run, base: Time.current.change(usec: 0))
      ingest_run_event(run, 1, "run.admitted", {
        workspace_key: @workspace.runner_key, task_key: run.crew_task.task_key,
        attempt: run.attempt_number
      }, occurred_at: base + 0.001.seconds)
      ingest_run_event(run, 2, "run.started", {
        adapter: run.selected_adapter_key, scenario: "m6-phase-proof", attempt: run.attempt_number
      }, occurred_at: base + 0.002.seconds)
      base
    end

    def publish_draft_artifact(support_case:, body:, citation:, usage: nil)
      install_crew_test_dependencies(workspace: @workspace, membership: @owner)
      task = CrewWork.create!(
        workspace: @workspace, membership: @owner, scope: support_case,
        profile: @workspace.agent_profiles.find_by!(role_key: "resolution_drafter"),
        title: "Draft current support answer", input_context: "Use the current support evidence.",
        expected_output: "Return a typed draft with cited claims."
      )
      start_task(task)
      payload = artifact_payload(kind: "draft", body:, citations: [ citation ])
      run = complete_run(task, payload, usage:)
      run.crew_artifact || raise("Expected the completed draft run to publish an artifact.")
    end

    def start_task(task)
      CrewWork.apply!(
        workspace: @workspace, membership: @owner, task:, command: :start,
        expected_sequence: task.current_event.sequence_number, attributes: {}
      )
    end

    def complete_run(task, payload, usage: nil)
      @output_counter = @output_counter.to_i + 1
      run = ExecutionLedger.new(workspace: @workspace).prepare!(
        task:, request_key: "m6-artifact:#{task.id}:#{@output_counter}"
      )
      base = Time.current.change(usec: 0)
      ingest_run_event(run, 1, "run.admitted", {
        workspace_key: @workspace.runner_key, task_key: task.task_key, attempt: run.attempt_number
      }, occurred_at: base + 0.001.seconds)
      ingest_run_event(run, 2, "run.started", {
        adapter: run.selected_adapter_key, scenario: "m6-phase-proof", attempt: run.attempt_number
      }, occurred_at: base + 0.002.seconds)
      ingest_run_event(run, 3, "output.produced", { text: JSON.generate(payload) }, occurred_at: base + 0.003.seconds)
      sequence = 4
      if usage
        ingest_run_event(run, sequence, "usage.observed", usage, occurred_at: base + (sequence / 1_000.0).seconds)
        sequence += 1
      end
      ingest_run_event(run, sequence, "run.completed", { outcome: "completed" }, occurred_at: base + (sequence / 1_000.0).seconds)
      run.reload
    end

    def create_failed_run(support_case, code:)
      install_crew_test_dependencies(workspace: @workspace, membership: @owner)
      task = CrewWork.create!(
        workspace: @workspace, membership: @owner, scope: support_case,
        profile: @workspace.agent_profiles.find_by!(role_key: "support_investigator"),
        title: "Record the failed support attempt", input_context: "Use retained support evidence.",
        expected_output: "Return a bounded investigation."
      )
      start_task(task)
      run = ExecutionLedger.new(workspace: @workspace).prepare!(task:, request_key: "m6-failed-support")
      base = begin_run(run)
      ingest_run_event(run, 3, "run.failed", { code:, retryable: false }, occurred_at: base + 0.003.seconds)
      run.reload
    end

    def create_retryable_runner_failure
      install_crew_test_dependencies(workspace: @workspace, membership: @owner)
      task = CrewWork.create!(
        workspace: @workspace, membership: @owner, scope: @account,
        profile: @workspace.agent_profiles.find_by!(role_key: "risk_investigator"),
        title: "Retry definite runner failure", input_context: "Use retained facts.",
        expected_output: "Return a bounded result."
      )
      CrewWork.apply!(
        workspace: @workspace, membership: @owner, task:, command: :start,
        expected_sequence: task.current_event.sequence_number, attributes: {}
      )
      run = ExecutionLedger.new(workspace: @workspace).prepare!(task: task.reload, request_key: "m6-runner-failure")
      base = begin_run(run)
      ingest_run_event(run, 3, "run.failed", { code: "runner_unavailable", retryable: true }, occurred_at: base + 0.003.seconds)
      run.reload
    end

    def resolve_case(support_case)
      %i[triaged investigating draft_ready awaiting_human_review resolved].each do |status|
        CaseWorkflow.transition!(
          workspace: @workspace, support_case:, membership: @owner, to: status,
          reason: "M6 integrated journey", occurred_at: @now
        )
      end
    end

    def historical_conversation
      {
        "type" => "conversation", "id" => "m6-history-1", "created_at" => 90,
        "updated_at" => 100, "state" => "closed", "title" => "Retained historical request",
        "contacts" => { "contacts" => [
          { "type" => "contact", "id" => "m6-contact-1", "email" => "m6-history@example.net", "name" => "M6 History" }
        ] },
        "source" => {
          "id" => "m6-source-1", "part_type" => "contact_reply", "created_at" => 90,
          "body" => "Retain this historical request.",
          "author" => { "type" => "contact", "name" => "M6 History" }
        },
        "conversation_parts" => { "conversation_parts" => [] },
        "tags" => { "tags" => [] }
      }
    end

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
      install_crew_test_dependencies(workspace: @workspace, membership: @owner)
      profile = @workspace.agent_profiles.find_by!(role_key: "support_reviewer")
      task = CrewWork.create!(
        workspace: @workspace, membership: @owner, scope: support_case, profile:,
        title: "Review the qualified result", input_context: "Review current proof.",
        expected_output: "Approve only a grounded result."
      )
      start_task(task)
      payload = artifact_payload(
        kind: "quality_review", body: "The qualified result matches current evidence and preserves human send authority.",
        uncertainty: "The timing remains explicitly unconfirmed.", citations: target.citations, review_outcome: "approved"
      )
      review = complete_run(task, payload).crew_artifact
      raise("Expected the completed review run to publish an artifact.") unless review
      review_and_approve(task, "The qualified result is grounded and ready for human send.")
      review
    end

    def review_and_approve(task, body)
      task.reload
      CrewWork.apply!(
        workspace: @workspace, membership: @owner, task:, command: :request_review,
        expected_sequence: task.current_event.sequence_number, attributes: { body: }
      )
      task.reload
      CrewWork.apply!(
        workspace: @workspace, membership: @owner, task:, command: :review,
        expected_sequence: task.current_event.sequence_number,
        attributes: { review_outcome: "approved", body: }
      )
    end

    def artifact_payload(kind:, body:, citations:, uncertainty: "No uncertainty identified.", conflicts: [], review_outcome: nil)
      evidence = citations.first.slice("kind", "locator")
      categories = if %w[account_analysis risk_investigation intervention_plan success_review].include?(kind)
        %w[customer_account_fact promised_action_date]
      else
        %w[customer_account_fact product_technical_fact]
      end
      {
        "schema_version" => 2, "kind" => kind, "body" => body, "uncertainty" => uncertainty,
        "citations" => citations, "conflicts" => conflicts, "change_requests" => [],
        "review_outcome" => review_outcome, "memory_proposals" => [],
        "required_facts" => %w[customer_report reset_policy],
        "material_claims" => categories.each_with_index.map do |category, index|
          {
            "key" => index.zero? ? "customer_report" : "reset_policy", "category" => category,
            "text" => body, "state" => "supported", "evidence" => [ evidence ]
          }
        end,
        "proposed_actions" => [],
        "policy_checks" => ResolutionContractVersion::REVIEW_CHECKS.keys.sort.map do |check|
          { "check" => check, "status" => "passed" }
        end
      }
    end

    def create_policy_source(label, retrieved_at:)
      KnowledgeIngestion.ingest_integration!(
        workspace: @workspace, source_kind: :intercom_help_center,
        title: "M6 #{label} policy", content: "The #{label} support policy.",
        external_id: "m6-#{label}-policy", source_updated_at: retrieved_at, retrieved_at:
      )
    end

    def knowledge_citation(source)
      { "kind" => "knowledge", "locator" => source.current_version.citation_uri, "label" => source.title }
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
