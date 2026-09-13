require "test_helper"

class OperatingWorkspaceJourneyTest < ActiveSupport::TestCase
  class RecordingTransport
    attr_reader :deliveries

    def initialize(error: nil)
      @error = error
      @deliveries = []
    end

    def deliver!(**attributes)
      @deliveries << attributes
      raise @error if @error

      true
    end
  end

  setup do
    @at = Time.zone.parse("2026-08-24 12:00:00")
  end

  test "fourteen-step operating workspace journey stays isolated" do
    travel_to @at
    primary, owner, foreign, foreign_owner = create_isolated_workspaces
    admin = primary.memberships.create!(
      user: User.create!(email_address: "e1-admin@example.com", password: "password12345", verified_at: @at),
      role: :admin
    )
    Current.session = owner.user.sessions.create!(authentication_method: :local, expires_at: @at + 12.hours)

    imported = import_approaching_renewal(workspace: primary, membership: owner)
    support_case = ingest_support_case(workspace: primary, account: imported)
    assert_equal imported, support_case.conversation.contact.account
    first_health = imported.reload.current_health_assessment
    assert_equal imported.health_inputs.find_by!(input_key: "renewal_on").date_value, first_health.renewal_on
    assert first_health.renewal_on.between?(@at.to_date, @at.to_date + AccountHealth::RENEWAL_WINDOW_DAYS)

    blocked = create_draft_artifact(
      workspace: primary, support_case:, membership: owner,
      body: "I cannot cite a current reset policy.", result_state: "blocked",
      blocker_message: "Applicable knowledge is missing."
    )
    assert blocked.contract_blocking?
    quality = SupportQualityReadout.build(workspace: primary)
    assert quality.metrics.find { |metric| metric.key == "blocked_drafts" }.value >= 1
    assert quality.blocked_drafts.any? { |row| row.artifact == blocked }

    candidate = KnowledgeImprovementWorkflow.create_from_blocked_draft!(
      workspace: primary, membership: owner, artifact: blocked, at: @at
    )
    KnowledgeImprovementWorkflow.assign!(
      workspace: primary, membership: owner, candidate:, assignee: owner, at: @at + 1.minute
    )
    assert_equal "assigned", candidate.reload.status
    assert_equal owner, candidate.assigned_to_membership

    knowledge = KnowledgeIngestion.create!(
      workspace: primary, membership: owner, source_kind: :manual,
      title: "Current browser recovery", content: "Use the current recovery link after identity checks."
    )
    KnowledgeImprovementWorkflow.resolve!(
      workspace: primary, membership: owner, candidate:, knowledge_source: knowledge, at: @at + 2.minutes
    )
    assert_equal "resolved", candidate.reload.status
    assert_equal knowledge.current_version, candidate.resolved_knowledge_source_version

    grounded = create_draft_artifact(
      workspace: primary, support_case:, membership: owner,
      body: "Use the current recovery link after identity checks.", result_state: "complete"
    )
    assert_equal "complete", grounded.contract_result_state
    assert_not grounded.contract_blocking?

    draft = EmailDraftWorkflow.save!(
      workspace: primary, support_case:, membership: owner,
      body: grounded.body, expected_lock_version: "new",
      source_crew_artifact_id: grounded.id, adopt_source: true
    )
    reviewed_body = "We confirmed the current recovery link. Timing remains unconfirmed."
    draft = EmailDraftWorkflow.save!(
      workspace: primary, support_case:, membership: owner,
      body: reviewed_body, expected_lock_version: draft.lock_version.to_s,
      source_crew_artifact_id: grounded.id
    )
    preview = HumanEmailSend.recipient_preview(workspace: primary, support_case:)
    transport = RecordingTransport.new
    delivery = HumanEmailSend.send!(
      workspace: primary, support_case:, membership: owner, body: reviewed_body,
      draft_version: draft.lock_version.to_s, idempotency_key: "e1-human-send",
      source_crew_artifact_id: grounded.id, expected_recipient_address: preview.address,
      expected_inbound_message_id: preview.inbound_message_id, transport:
    )
    assert delivery.sent?
    assert_equal owner, delivery.actor_membership
    assert_equal reviewed_body, transport.deliveries.sole.fetch(:body)

    import_material_health_drop(workspace: primary, membership: owner, account: imported)
    changed = imported.reload.current_health_assessment
    assert changed.material_change?
    queue = AccountWorkQueue.new(workspace: primary, as_of: @at.to_date)
    attention = queue.page(view: "needs_attention")
    assert attention.rows.any? { |row|
      row.account == imported && row.inclusion_reasons.include?("material_change")
    }

    plan, = create_reviewed_intervention_plan(
      workspace: primary, account: imported, membership: owner, assessment: changed
    )
    intervention = propose_test_intervention(
      workspace: primary, account: imported, membership: owner, assessment: changed,
      artifact: plan, at: @at + 3.minutes
    )
    CustomerSuccessInterventionWorkflow.approve!(
      workspace: primary, membership: owner, intervention:, at: @at + 4.minutes
    )
    CustomerSuccessInterventionWorkflow.complete!(
      workspace: primary, membership: owner, intervention:, at: @at + 5.minutes
    )
    after = AccountHealth.recalculate!(
      workspace: primary, account: imported, trigger_kind: "human_request",
      membership: owner, at: @at + 1.hour
    )
    review = CustomerSuccessInterventionWorkflow.review!(
      workspace: primary, membership: owner, intervention:, after_assessment: after,
      uncertainty: "Timing alone cannot establish cause.", at: @at + 2.hours
    )
    assert_equal "reviewed", intervention.reload.status
    assert_equal after, review.after_account_health_assessment

    install_crew_test_dependencies(workspace: primary, membership: owner)
    scorecard = HealthScorecardDesigner.install_default!(workspace: primary)
    published_before = scorecard.current_version
    historical = imported.health_assessments.order(:id).first
    historical_score = historical.score
    historical_version = historical.health_scorecard_version

    parent_run = generate_scorecard_proposal(
      workspace: primary, membership: owner,
      prompt: "Make approaching renewal and repeated SLA breaches matter more."
    )
    parent = complete_scorecard_proposal(primary, parent_run, renewal: 40, sla: 35)
    revision_run = generate_scorecard_proposal(
      workspace: primary, membership: owner,
      prompt: "Raise SLA-breach weight further and keep renewal proximity.",
      parent_proposal: parent, expected_latest_proposal_id: parent.id
    )
    revision = complete_scorecard_proposal(primary, revision_run, renewal: 40, sla: 50)
    assert_equal parent, revision.parent_proposal
    version = HealthScorecardProposalWorkflow.accept!(
      workspace: primary, membership: owner, proposal: revision, expected_proposal_id: revision.id
    )
    assert_equal published_before, scorecard.reload.current_version
    backtest = HealthScorecardBacktester.run!(workspace: primary, membership: admin, version:, at: @at)
    published = HealthScorecardPublisher.publish!(
      workspace: primary, membership: admin, version:,
      expected_current_version_id: scorecard.current_version_id, expected_backtest_id: backtest.id
    )
    assert_equal version, published
    assert_equal version, scorecard.reload.current_version
    assert_equal historical_score, historical.reload.score
    assert_equal historical_version, historical.health_scorecard_version
    later = AccountHealth.recalculate!(
      workspace: primary, account: imported, trigger_kind: "human_request",
      membership: owner, at: @at + 3.hours
    )
    assert_equal version, later.health_scorecard_version

    assert_empty foreign.support_cases
    assert_empty foreign.knowledge_improvement_candidates
    assert_empty foreign.customer_success_interventions
    assert_empty foreign.health_scorecard_proposals
    assert_nil foreign.accounts.find_by(name: imported.name)
    assert_raises(ActiveRecord::RecordNotFound) do
      KnowledgeImprovementWorkflow.assign!(
        workspace: foreign, membership: foreign_owner, candidate:, assignee: foreign_owner
      )
    end
    assert_raises(ActiveRecord::RecordNotFound) do
      HealthScorecardPublisher.publish!(
        workspace: foreign, membership: foreign_owner, version:,
        expected_current_version_id: scorecard.current_version_id, expected_backtest_id: backtest.id
      )
    end
  end

  test "memory unavailable continues without false recall" do
    workspace = workspaces(:acme_support)
    owner = memberships(:owner_support)
    support_case = create_support_case(subject: "Memory outage")
    install_crew_test_dependencies(workspace:, membership: owner)
    memory = workspace.memory_records.create!(
      memory_type: :episodic, scope_kind: :workspace, topic: "e1-memory-outage",
      content: "Durable context for the outage journey.", authority: :source_record, origin_kind: :system,
      source_reference: "test://e1-memory-outage", source_digest: Digest::SHA256.hexdigest("e1-memory-outage"),
      observed_at: 1.hour.ago, valid_from: 1.hour.ago, confidence: 1, retention_policy: :indefinite
    )
    workspace.memory_index_entries.create!(
      memory_record: memory, status: :indexed, external_document_id: "document-#{memory.memory_key}",
      external_status: "done", attempt_count: 1, last_attempted_at: Time.current, indexed_at: Time.current
    )
    task = CrewWork.create!(
      workspace:, membership: owner, scope: support_case,
      profile: workspace.agent_profiles.find_by!(role_key: "support_investigator"),
      title: "Investigate with memory", input_context: "Use retrieved memory when available.",
      expected_output: "Return cited findings."
    )
    unavailable = Object.new
    unavailable.define_singleton_method(:search) { |query:| raise SupermemoryEngine::Unavailable, query.text }

    run = ExecutionLedger.new(workspace:, memory_engine: unavailable)
      .prepare!(task:, request_key: "e1-memory-unavailable")

    assert run.memory_degraded?
    assert_equal "unavailable", run.memory_context_detail
    assert_empty run.execution_memory_selections
  end

  test "runtime unavailable is recorded as a failed run" do
    workspace = workspaces(:acme_support)
    owner = memberships(:owner_support)
    support_case = create_support_case(subject: "Runtime outage")
    install_crew_test_dependencies(workspace:, membership: owner)
    task = CrewWork.create!(
      workspace:, membership: owner, scope: support_case,
      profile: workspace.agent_profiles.find_by!(role_key: "support_investigator"),
      title: "Retry definite runner failure", input_context: "Use retained facts.",
      expected_output: "Return a bounded result."
    )
    CrewWork.apply!(
      workspace:, membership: owner, task:, command: :start,
      expected_sequence: task.current_event.sequence_number, attributes: {}
    )
    run = ExecutionLedger.new(workspace:).prepare!(task: task.reload, request_key: "e1-runtime-unavailable")
    ledger = ExecutionLedger.new(workspace:)
    base = Time.current.change(usec: 0)
    [
      [ 1, "run.admitted", { workspace_key: workspace.runner_key, task_key: task.task_key, attempt: run.attempt_number } ],
      [ 2, "run.started", { adapter: run.selected_adapter_key, scenario: "e1-runtime", attempt: run.attempt_number } ],
      [ 3, "run.failed", { code: "runner_unavailable", retryable: true } ]
    ].each do |sequence, type, data|
      ledger.ingest!(event: {
        "protocol_version" => "v1", "event_id" => SecureRandom.uuid, "run_id" => run.run_key,
        "sequence" => sequence, "event_type" => type,
        "occurred_at" => (base + sequence.seconds).iso8601(6), "data" => data.deep_stringify_keys
      })
    end

    assert_equal "failed", run.reload.status
    assert_equal "runner_unavailable", run.failure_code
  end

  test "stale scorecard preview cannot publish until refreshed" do
    workspace = workspaces(:acme_support)
    owner = memberships(:owner_support)
    account = workspace.accounts.create!(name: "Stale Preview Account")
    AccountHealth.recalculate!(workspace:, account:, trigger_kind: "human_request", membership: owner, at: @at)
    version = HealthScorecardDesigner.propose!(
      workspace:, membership: owner, prompt: "Focus the score on clear renewal risk.",
      healthy_min: 75, watch_min: 50, weights: { "open_cases" => 40 }
    )
    backtest = HealthScorecardBacktester.run!(workspace:, membership: owner, version:, at: @at)
    AccountHealth.recalculate!(workspace:, account:, trigger_kind: "schedule", membership: owner, at: @at + 1.day)

    error = assert_raises(HealthScorecardPublisher::InvalidPublish) do
      HealthScorecardPublisher.publish!(
        workspace:, membership: owner, version:,
        expected_current_version_id: workspace.health_scorecard.current_version_id,
        expected_backtest_id: backtest.id
      )
    end
    assert_match(/snapshots changed/i, error.message)
  end

  test "ineligible assignees are rejected for knowledge and intervention ownership" do
    workspace = workspaces(:acme_support)
    owner = memberships(:owner_support)
    viewer = workspace.memberships.create!(
      user: User.create!(email_address: "e1-viewer@example.com", password: "password12345", verified_at: @at),
      role: :viewer
    )
    member = workspace.memberships.create!(
      user: User.create!(email_address: "e1-member@example.com", password: "password12345", verified_at: @at),
      role: :member
    )
    support_case = create_support_case(subject: "Ineligible assignee")
    artifact = create_draft_artifact(
      workspace:, support_case:, membership: owner, body: "Blocked.", result_state: "blocked"
    )
    candidate = KnowledgeImprovementWorkflow.create_from_blocked_draft!(
      workspace:, membership: owner, artifact:
    )
    error = assert_raises(KnowledgeImprovementWorkflow::InvalidCommand) do
      KnowledgeImprovementWorkflow.assign!(workspace:, membership: owner, candidate:, assignee: viewer)
    end
    assert_equal "Choose a human who can maintain knowledge.", error.message

    account = workspace.accounts.create!(name: "Intervention Assignee")
    assessment = AccountHealth.recalculate!(workspace:, account:, trigger_kind: "human_request", membership: owner, at: @at)
    plan, = create_reviewed_intervention_plan(workspace:, account:, membership: owner, assessment:)
    intervention = propose_test_intervention(
      workspace:, account:, membership: owner, assessment:, artifact: plan, accountable_membership: member, at: @at
    )
    error = assert_raises(CustomerSuccessInterventionWorkflow::InvalidCommand) do
      CustomerSuccessInterventionWorkflow.reassign!(
        workspace:, membership: owner, intervention:, accountable_membership: viewer,
        reason: "Viewers cannot own completion."
      )
    end
    assert_equal "Choose a human who can complete Account work.", error.message
  end

  test "unknown send outcome stays reviewable and is not treated as sent" do
    workspace = workspaces(:acme_support)
    owner = memberships(:owner_support)
    Current.session = owner.user.sessions.create!(authentication_method: :local, expires_at: @at + 12.hours)
    support_case = ingest_support_case(workspace:, account: accounts(:acme), email: "alice@example.net")
    draft = EmailDraftWorkflow.save!(
      workspace:, support_case:, membership: owner, body: "A human reply", expected_lock_version: "new"
    )
    preview = HumanEmailSend.recipient_preview(workspace:, support_case:)
    delivery = HumanEmailSend.send!(
      workspace:, support_case:, membership: owner, body: "A human reply",
      draft_version: draft.lock_version.to_s, idempotency_key: "e1-unknown-send",
      expected_recipient_address: preview.address, expected_inbound_message_id: preview.inbound_message_id,
      transport: RecordingTransport.new(error: Net::ReadTimeout.new("timeout"))
    )

    assert delivery.unknown?
    assert_not delivery.sent?
    assert delivery.email_draft.reload.sending?
  end

  test "missing cost stays unknown and is never shown as zero" do
    workspace = workspaces(:acme_support)
    owner = memberships(:owner_support)
    support_case = create_support_case(subject: "Missing cost")
    install_crew_test_dependencies(workspace:, membership: owner)
    task = CrewWork.create!(
      workspace:, membership: owner, scope: support_case,
      profile: workspace.agent_profiles.find_by!(role_key: "support_investigator"),
      title: "Cost unknown run", input_context: "Use retained facts.",
      expected_output: "Return a bounded result."
    )
    run = ExecutionLedger.new(workspace:).prepare!(task:, request_key: "e1-missing-cost")
    ledger = ExecutionLedger.new(workspace:)
    base = Time.current.change(usec: 0)
    [
      [ 1, "run.admitted", { workspace_key: workspace.runner_key, task_key: task.task_key, attempt: run.attempt_number } ],
      [ 2, "run.started", { adapter: "scripted", scenario: "e1-cost", attempt: run.attempt_number } ],
      [ 3, "run.failed", { code: "scripted_failure", retryable: false } ]
    ].each do |sequence, type, data|
      ledger.ingest!(event: {
        "protocol_version" => "v1", "event_id" => SecureRandom.uuid, "run_id" => run.run_key,
        "sequence" => sequence, "event_type" => type,
        "occurred_at" => (base + sequence.seconds).iso8601(6), "data" => data.deep_stringify_keys
      })
    end
    snapshot = run.reload.usage_cost_snapshot

    assert snapshot.not_reported?
    assert_nil snapshot.amount_micros
    assert_not_equal 0, snapshot.amount_micros
    assert_equal "usage_not_reported", snapshot.calculation_provenance.fetch("reason")
  end

  test "insufficient follow-up data cannot close an intervention review" do
    workspace = workspaces(:acme_support)
    owner = memberships(:owner_support)
    account = workspace.accounts.create!(name: "Insufficient Follow-up")
    assessment = AccountHealth.recalculate!(workspace:, account:, trigger_kind: "human_request", membership: owner, at: @at)
    plan, = create_reviewed_intervention_plan(workspace:, account:, membership: owner, assessment:)
    intervention = propose_test_intervention(
      workspace:, account:, membership: owner, assessment:, artifact: plan, at: @at
    )
    CustomerSuccessInterventionWorkflow.approve!(workspace:, membership: owner, intervention:, at: @at + 1.minute)
    CustomerSuccessInterventionWorkflow.complete!(workspace:, membership: owner, intervention:, at: @at + 2.minutes)

    error = assert_raises(CustomerSuccessInterventionWorkflow::InvalidCommand) do
      CustomerSuccessInterventionWorkflow.review!(
        workspace:, membership: owner, intervention:, after_assessment: assessment,
        uncertainty: "No later snapshot exists."
      )
    end
    assert_equal "Choose a newer deterministic assessment calculated after completion.", error.message
  end

  private
    def create_isolated_workspaces
      primary = organizations(:acme).workspaces.create!(name: "E1 Operating", slug: "e1-operating")
      owner = primary.memberships.create!(user: users(:owner), role: :owner)
      foreign = organizations(:beta).workspaces.create!(name: "E1 Isolated", slug: "e1-isolated")
      foreign_owner = foreign.memberships.create!(user: users(:outsider), role: :owner)
      [ primary, owner, foreign, foreign_owner ]
    end

    def import_approaching_renewal(workspace:, membership:)
      AccountDataImport.import_api!(workspace:, membership:, rows: [ {
        source_id: "e1-renewal-baseline", observed_at: @at.iso8601,
        account_name: "E1 Journey Account", contact_name: "E1 Customer",
        contact_email: "e1-customer@example.net", renewal_on: "2026-09-13",
        active_users: 90, licensed_seats: 100
      } ])
      workspace.accounts.find_by!(name: "E1 Journey Account")
    end

    def import_material_health_drop(workspace:, membership:, account:)
      AccountDataImport.import_api!(workspace:, membership:, rows: [ {
        source_id: "e1-renewal-drop", observed_at: (@at + 10.minutes).iso8601,
        account_name: account.name, renewal_on: "2026-09-10",
        active_users: 10, licensed_seats: 100
      } ])
    end

    def ingest_support_case(workspace:, account:, email: "e1-customer@example.net")
      inbox = workspace.shared_email_inboxes.create!(
        name: "E1 Support", email_address: "e1-support-#{workspace.id}@example.com",
        credential_key: "e1support#{workspace.id}"
      )
      delivery = SharedEmailIntake.receive!(
        inbox:, raw_email: raw_support_email(from: email, to: inbox.email_address),
        received_at: @at
      )
      support_case = delivery.conversation.support_case
      contact = support_case.conversation.contact
      contact.update!(account:) if contact.account_id != account.id
      support_case
    end

    def raw_support_email(from:, to:)
      [
        "From: E1 Customer <#{from}>",
        "To: Support <#{to}>",
        "Date: Mon, 24 Aug 2026 11:55:00 +0000",
        "Subject: Browser recovery is missing",
        "Message-ID: <e1-#{SecureRandom.hex(8)}@example.net>",
        "MIME-Version: 1.0",
        "Content-Type: text/plain; charset=UTF-8",
        "",
        "I still cannot recover access with the current article."
      ].join("\r\n")
    end

    def generate_scorecard_proposal(workspace:, membership:, prompt:, parent_proposal: nil, expected_latest_proposal_id: nil)
      HealthScorecardProposalWorkflow.generate!(
        workspace:, membership:, prompt:, parent_proposal:, expected_latest_proposal_id:, admit: false
      )
    end

    def complete_scorecard_proposal(workspace, run, renewal:, sla:)
      ledger = ExecutionLedger.new(workspace:)
      output = JSON.generate(
        schema_version: 1, kind: "scorecard_proposal",
        definition: {
          "schema_version" => 1, "healthy_min" => 75, "watch_min" => 50,
          "rules" => [
            { "signal_key" => "renewal_on", "weight" => renewal },
            { "signal_key" => "sla_breaches", "weight" => sla }
          ]
        },
        explanation: "I changed only catalog renewal and SLA weights. This does not calculate account scores.",
        assumptions: [ "Only retained catalog signals can change the score." ],
        unsupported_requests: [], missing_evidence: []
      )
      [
        [ 1, "run.admitted", { workspace_key: workspace.runner_key, task_key: run.crew_task.task_key, attempt: run.attempt_number } ],
        [ 2, "run.started", { adapter: "scripted", scenario: "scorecard", attempt: run.attempt_number } ],
        [ 3, "output.produced", { text: output } ],
        [ 4, "run.completed", { outcome: "completed" } ]
      ].each do |sequence, type, data|
        ledger.ingest!(event: {
          "protocol_version" => "v1", "event_id" => SecureRandom.uuid, "run_id" => run.run_key,
          "sequence" => sequence, "event_type" => type,
          "occurred_at" => (@at + sequence.seconds).iso8601(6),
          "data" => data.deep_stringify_keys
        })
      end
      workspace.health_scorecard_proposals.find_by!(execution_run: run)
    end
end
