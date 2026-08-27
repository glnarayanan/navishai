require "test_helper"

class OutcomeExplanationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
    @support_case = create_support_case(subject: "Explain retained outcome")
    @account = @support_case.conversation.contact.account
    sign_in_as @owner.user
  end

  test "renders read-only case and Account explanations without inventing zero usage" do
    get explanation_path("case", @support_case)

    assert_response :success
    assert_select "h1", "Explain this outcome"
    assert_select ".explanation-state-empty", "Empty"
    assert_select ".usage-state-not-reported", "Not reported"
    assert_select ".usage-cost-summary", text: /This is not a zero-cost claim/
    assert_select ".explanation-usage", text: /Frozen budget: 0 units/
    assert_select ".outcome-explanation form", count: 0

    get explanation_path("account", @account)
    assert_response :success
    assert_select ".explanation-outcome", text: /No outcome recorded/
  end

  test "resolves run and health lineage through Workspace-scoped routes" do
    approve_scripted_runtime(workspace: @workspace, membership: @owner)
    CrewConfiguration.install_defaults!(workspace: @workspace)
    profile = @workspace.agent_profiles.find_by!(role_key: "support_coordinator")
    task = CrewWork.create!(
      workspace: @workspace, membership: @owner, scope: @support_case, profile:,
      title: "Explain one run", input_context: "Use retained facts.",
      expected_output: "Return a bounded result."
    )
    run = ExecutionLedger.new(workspace: @workspace).prepare!(task:, request_key: "explain:route")
    assessment = AccountHealth.recalculate!(
      workspace: @workspace, account: @account, trigger_kind: "human_request",
      membership: @owner, at: Time.current.change(usec: 0)
    )

    get explanation_path("run", run)
    assert_response :success
    assert_select ".explanation-outcome", text: /Admitting/
    assert_select ".explanation-lineage", text: /Explain one run/
    assert_select ".explanation-usage", text: /Unavailable by run/

    get explanation_path("health-assessment", assessment)
    assert_response :success
    assert_select "#health-lineage-title", "Health outcome and evidence"
    assert_select ".explanation-facts", text: /#{assessment.score}\/100/
    assert_select ".explanation-record-list", text: /Open cases/
  end

  test "fails closed for foreign subjects and hides governed memory from Viewers" do
    foreign_case = create_support_case(
      subject: "Foreign secret", workspace: workspaces(:beta_support),
      contact: contacts(:bob), membership: memberships(:outsider_beta)
    )

    get explanation_path("case", foreign_case)
    assert_response :not_found

    viewer_user = User.create!(
      email_address: "explanation-viewer@example.com", password: "password12345", verified_at: Time.current
    )
    @workspace.memberships.create!(user: viewer_user, role: :viewer)
    sign_in_as viewer_user
    get explanation_path("case", @support_case)

    assert_response :success
    assert_select "#memory-title", "Selected memory and provenance"
    assert_select ".muted-copy", text: /cannot inspect selected memory/
  end

  test "renders an honest error state when authoritative records cannot be read" do
    original = OutcomeExplanation.method(:resolve!)
    OutcomeExplanation.define_singleton_method(:resolve!) do |**|
      raise ActiveRecord::ConnectionNotEstablished, "private database detail"
    end

    get explanation_path("case", @support_case)

    assert_response :service_unavailable
    assert_select "h1", "Explanation couldn’t be loaded"
    assert_select ".empty-state", text: /No outcome or usage value was inferred/
    refute_includes response.body, "private database detail"
  ensure
    OutcomeExplanation.define_singleton_method(:resolve!, original)
  end

  test "shows selected memory provenance to an authorized role without exposing its broad body" do
    install_crew
    profile = @workspace.agent_profiles.find_by!(role_key: "support_coordinator")
    task = create_task(profile, "Memory provenance")
    run = ExecutionLedger.new(workspace: @workspace).prepare!(
      task:, request_key: "explain:memory"
    )
    memory = @workspace.memory_records.create!(
      memory_type: :episodic, scope_kind: :workspace, topic: "Approved reset pattern",
      content: "private broad memory body", authority: :source_record, origin_kind: :system,
      source_reference: "case-policy://reset-v3", source_digest: Digest::SHA256.hexdigest("memory"),
      observed_at: 1.hour.ago, valid_from: 1.hour.ago, confidence: 1,
      retention_policy: :indefinite
    )
    @workspace.execution_memory_selections.create!(
      execution_run: run, memory_record: memory, rank: 1, relevance_score: 0.9
    )
    now = Time.current.change(usec: 0)
    revision_base = memory.attributes.except(
      "id", "memory_key", "content", "content_digest", "source_reference", "source_digest",
      "supersedes_memory_record_id", "observed_at", "valid_from", "created_at", "updated_at"
    )
    MemoryRecord.insert_all!(120.times.map do |index|
      content = "revision #{index}"
      revision_base.merge(
        "memory_key" => SecureRandom.uuid, "content" => content,
        "content_digest" => Digest::SHA256.hexdigest(content),
        "source_reference" => "case-policy://reset-v3/revisions/#{index}",
        "source_digest" => Digest::SHA256.hexdigest("revision-#{index}"),
        "supersedes_memory_record_id" => memory.id,
        "observed_at" => now + index.seconds, "valid_from" => now + index.seconds,
        "created_at" => now, "updated_at" => now
      )
    end)

    explanation = OutcomeExplanation.resolve!(
      workspace: @workspace, membership: @owner, subject_type: "case", subject_id: @support_case.id
    )
    selected_memory = explanation.memory_selections.sole.memory_record
    assert explanation.memory_superseded?(selected_memory)
    refute selected_memory.association(:revisions).loaded?

    get explanation_path("case", @support_case)

    assert_response :success
    assert_select "#memory-title", "Selected memory and provenance"
    assert_select ".explanation-record-list", text: /Approved reset pattern/
    assert_select ".explanation-record-list", text: /case-policy:\/\/reset-v3/
    assert_select ".explanation-record-list", text: /superseded/
    refute_includes response.body, "private broad memory body"
  end

  test "recent run lineage includes a retry on an older task beyond the task cap" do
    install_crew
    profile = @workspace.agent_profiles.find_by!(role_key: "support_coordinator")
    older_task = create_task(profile, "Older task with newest retry")
    ExecutionLedger.new(workspace: @workspace).prepare!(
      task: older_task, request_key: "explain:older:first"
    )
    OutcomeExplanation::DETAIL_LIMITS.fetch(:tasks).times do |index|
      create_task(profile, "Newer task #{index}")
    end
    retry_run = ExecutionLedger.new(workspace: @workspace).prepare!(
      task: older_task, request_key: "explain:older:retry"
    )

    explanation = OutcomeExplanation.resolve!(
      workspace: @workspace, membership: @owner, subject_type: "case", subject_id: @support_case.id
    )

    assert_equal retry_run, explanation.runs.first
    assert_equal older_task, explanation.tasks.first
    assert_includes explanation.tasks, retry_run.crew_task
    assert_equal 1, explanation.omitted_counts.fetch(:tasks)
    assert_equal 2, explanation.usage.run_count
    assert_equal 0, explanation.omitted_counts.fetch(:runs)

    get explanation_path("case", @support_case)
    assert_response :success
    assert_select ".explanation-lineage > li", count: OutcomeExplanation::DETAIL_LIMITS.fetch(:tasks)
    assert_select ".explanation-lineage > li:first-child", text: /Older task with newest retry/
    assert_select ".explanation-history-limit", text: /1 specialist task/
  end

  test "current blocked work leads the summary when recent run lineage fills the task cap" do
    install_crew
    profile = @workspace.agent_profiles.find_by!(role_key: "support_coordinator")
    blocked_task = create_task(profile, "Older blocked task without a run")
    CrewWork.apply!(
      workspace: @workspace, membership: @owner, task: blocked_task,
      command: "block", expected_sequence: blocked_task.current_event.sequence_number,
      attributes: { body: "A human decision is required." }
    )
    OutcomeExplanation::DETAIL_LIMITS.fetch(:tasks).times do |index|
      task = create_task(profile, "Recent run task #{index}")
      ExecutionLedger.new(workspace: @workspace).prepare!(
        task:, request_key: "explain:recent:#{index}"
      )
    end

    explanation = OutcomeExplanation.resolve!(
      workspace: @workspace, membership: @owner, subject_type: "case", subject_id: @support_case.id
    )

    assert_equal "blocked", explanation.outcome_state
    assert_equal "Older blocked task without a run", explanation.tasks.first.title
    assert_equal OutcomeExplanation::DETAIL_LIMITS.fetch(:tasks), explanation.tasks.size
    assert_equal OutcomeExplanation::DETAIL_LIMITS.fetch(:runs) - 1, explanation.runs.size
    assert_equal 1, explanation.omitted_counts.fetch(:tasks)
    assert_equal 1, explanation.omitted_counts.fetch(:runs)
    assert_equal "Review the task record and choose the next human action.", explanation.next_action
    assert explanation.runs.all? { |run| explanation.tasks.include?(run.crew_task) }

    get explanation_path("case", @support_case)
    assert_response :success
    assert_select ".explanation-state-blocked", "Blocked"
    assert_select ".explanation-blockers", text: /Older blocked task without a run is blocked/
    assert_select ".explanation-history-limit", text: /1 specialist task.*1 execution run/m
  end

  test "reconciles partial run search budget and money totals without treating gaps as zero" do
    install_crew
    UsageRateConfiguration.publish!(
      workspace: @workspace, membership: @owner,
      attributes: {
        expected_current_version_id: nil, currency: "USD", source_name: "Controller test rate",
        input_rate: "2", output_rate: "", search_rate: "5"
      }
    )
    coordinator = @workspace.agent_profiles.find_by!(role_key: "support_coordinator")
    first_task = create_task(coordinator, "Reported run")
    second_task = create_task(coordinator, "Unreported run")
    first = ExecutionLedger.new(workspace: @workspace).prepare!(
      task: first_task, request_key: "explain:usage:reported"
    )
    start_run(first, scenario: "hidden-sensitive-scenario")
    ingest(first, 3, "usage.observed", input_units: 10, output_units: 5)
    ingest(first, 4, "run.failed", code: "scripted_failure", retryable: false)
    second = ExecutionLedger.new(workspace: @workspace).prepare!(
      task: second_task, request_key: "explain:usage:unreported"
    )
    start_run(second)
    ingest(second, 3, "run.failed", code: "scripted_failure", retryable: false)

    investigator = @workspace.agent_profiles.find_by!(role_key: "support_investigator")
    search_task = create_task(investigator, "Search usage")
    completed_search(search_task, request_key: "explain:search:reported", cost_units: 100)
    failed = Object.new
    failed.define_singleton_method(:web_search!) { |**| raise RunnerClient::Unavailable, "offline" }
    assert_raises(RunnerClient::Unavailable) do
      PublicWebResearch.perform!(
        workspace: @workspace, membership: @owner, task: search_task,
        query: "public failure", request_key: "explain:search:unreported", client: failed
      )
    end

    explanation = OutcomeExplanation.resolve!(
      workspace: @workspace, membership: @owner, subject_type: "case", subject_id: @support_case.id
    )
    usage = explanation.usage
    assert_equal 2, usage.run_count
    assert_equal 2, usage.search_count
    assert_equal "partial", usage.run_state
    assert_equal "partial", usage.search_state
    assert_equal 10, usage.input_units
    assert_equal 5, usage.output_units
    assert_equal 100, usage.search_units
    assert_equal 250_000, usage.budget_units
    assert_equal 15, usage.budget_used_units
    assert_equal "partial", usage.cost_state
    assert_equal({ "USD" => 520 }, usage.amounts_by_currency)

    get explanation_path("case", @support_case)
    assert_response :success
    assert_select ".explanation-state-degraded", "Degraded"
    assert_select ".usage-state-partial", "Partial"
    assert_select ".usage-cost-summary-partial", text: /USD 0\.000520/
    assert_select ".usage-cost-summary", text: /Missing components are not treated as zero/
    assert_select "#recovery-title", "Failure and recovery"
    refute_includes response.body, "hidden-sensitive-scenario"
  end

  test "shows blocked refused outcomes without exposing policy event detail" do
    install_crew
    coordinator = @workspace.agent_profiles.find_by!(role_key: "support_coordinator")
    task = create_task(coordinator, "Denied run")
    run = ExecutionLedger.new(workspace: @workspace).prepare!(task:, request_key: "explain:denied")
    start_run(run)
    ingest(run, 3, "run.policy_denied", code: "prompt_exfiltration", tool: "secret_shell")
    create_draft_artifact(
      workspace: @workspace, support_case: @support_case, membership: @owner,
      body: "Refused unsafe request", result_state: "needs_human", claim_state: "refused",
      blocker_message: "The request is refused.", remediation: "A human must choose a safe next step."
    )

    get explanation_path("case", @support_case)

    assert_response :success
    assert_select ".explanation-state-blocked", "Blocked"
    assert_select ".claim-state-refused", "Refused"
    assert_select ".explanation-summary", text: /Uncertain/
    assert_select ".explanation-blockers", text: /request is refused/
    refute_includes response.body, "secret_shell"
  end

  test "distinguishes complete stale and conflicted proof states" do
    create_draft_artifact(
      workspace: @workspace, support_case: @support_case, membership: @owner,
      body: "Supported current answer", result_state: "complete"
    )
    get explanation_path("case", @support_case)
    assert_response :success
    assert_select ".explanation-state-complete", "Complete"
    assert_select ".explanation-summary", text: /Current/
    assert_select ".explanation-artifact-list", text: /Supported current answer/

    create_draft_artifact(
      workspace: @workspace, support_case: @support_case, membership: @owner,
      body: "Stale answer", result_state: "needs_human", evidence_status: "stale"
    )
    get explanation_path("case", @support_case)
    assert_response :success
    assert_select ".explanation-summary", text: /Stale/
    assert_select ".claim-state-uncertain", "Uncertain"

    create_draft_artifact(
      workspace: @workspace, support_case: @support_case, membership: @owner,
      body: "Conflicted answer", result_state: "needs_human",
      evidence_status: "conflicted", claim_state: "conflicted"
    )
    get explanation_path("case", @support_case)
    assert_response :success
    assert_select ".explanation-summary", text: /Conflicted/
    assert_select ".claim-state-conflicted", "Conflicted"
  end

  test "reconstructs a human-edited draft and final human send" do
    inbox = @workspace.shared_email_inboxes.create!(
      name: "Explanation inbox", email_address: "explain@example.com", credential_key: "explain"
    )
    thread = @workspace.email_threads.create!(
      shared_email_inbox: inbox, conversation: @support_case.conversation,
      thread_key: "explanation-thread@example.com"
    )
    artifact = create_draft_artifact(
      workspace: @workspace, support_case: @support_case, membership: @owner,
      body: "Generated draft that must not be treated as sent", result_state: "needs_human"
    )
    draft = EmailDraftWorkflow.save!(
      workspace: @workspace, support_case: @support_case, membership: @owner,
      body: artifact.body, expected_lock_version: "new",
      source_crew_artifact_id: artifact.id, adopt_source: true
    )
    draft = EmailDraftWorkflow.save!(
      workspace: @workspace, support_case: @support_case, membership: @owner,
      body: "Exact human-edited final reply", expected_lock_version: draft.lock_version.to_s,
      source_crew_artifact_id: artifact.id
    )
    sent_at = Time.current.change(usec: 0)
    message = ConversationThread.append_outbound!(
      workspace: @workspace, conversation: @support_case.conversation, membership: @owner,
      body: draft.body, occurred_at: sent_at, source: :web
    )
    delivery = @workspace.outbound_email_deliveries.create!(
      email_draft: draft, shared_email_inbox: inbox, email_thread: thread,
      conversation: @support_case.conversation, conversation_message: message,
      actor_membership: @owner, actor_user: @owner.user,
      idempotency_key: "explanation-final-send", message_id: "explanation-final@navishai.local",
      from_address: inbox.email_address, to_address: "customer@example.com",
      subject: "Re: Explain retained outcome", body: draft.body, status: :sent,
      started_at: sent_at, sent_at:, **HumanDraftProvenance.delivery_attributes(draft)
    )
    draft.update!(status: :sent)
    AuditEvent.record!(
      action: "email.send_reviewed", source: :web, workspace: @workspace,
      actor: @owner.user, subject: delivery, metadata: { outcome: "accepted" }, occurred_at: sent_at
    )

    get explanation_path("case", @support_case)

    assert_response :success
    assert_select "#communication-title", "Human draft and final action"
    assert_select ".explanation-record-list", text: /human-edited by #{@owner.user.email_address}/
    assert_select ".explanation-record-list", text: /Exact human-edited final reply/
    assert_select ".explanation-record-list", text: /Human send decision · Accepted/
    assert_select ".explanation-summary", text: /No further action is recorded/
  end

  private
    def explanation_path(type, record)
      workspace_outcome_explanation_path(
        @workspace, subject_type: type, subject_id: record.id
      )
    end

    def install_crew
      approve_scripted_runtime(workspace: @workspace, membership: @owner)
      CrewConfiguration.install_defaults!(workspace: @workspace)
      ResolutionContractConfiguration.install_defaults!(workspace: @workspace)
    end

    def create_task(profile, title)
      CrewWork.create!(
        workspace: @workspace, membership: @owner, scope: @support_case, profile:, title:,
        input_context: "Use retained facts only.", expected_output: "Return a bounded result."
      )
    end

    def start_run(run, scenario: "explanation test")
      ingest(run, 1, "run.admitted",
        workspace_key: @workspace.runner_key, task_key: run.crew_task.task_key, attempt: run.attempt_number)
      ingest(run, 2, "run.started", adapter: "scripted", scenario:, attempt: run.attempt_number)
    end

    def ingest(run, sequence, event_type, **data)
      event = ExecutionLedger.new(workspace: @workspace).ingest!(event: {
        "protocol_version" => "v1", "event_id" => SecureRandom.uuid, "run_id" => run.run_key,
        "sequence" => sequence, "event_type" => event_type,
        "occurred_at" => (Time.current.change(usec: 0) + sequence.seconds).iso8601(6),
        "data" => data.stringify_keys
      })
      connection = ActiveRecord::Base.connection
      connection.execute("SET CONSTRAINTS ALL IMMEDIATE")
      connection.execute("SET CONSTRAINTS ALL DEFERRED")
      event
    end

    def completed_search(task, request_key:, cost_units:)
      response = {
        "protocol_version" => "v1", "workspace_key" => @workspace.runner_key,
        "request_key" => request_key, "query" => "public status history",
        "provider_key" => "searxng", "policy_decision" => "allowed", "cost_units" => cost_units,
        "retrieved_at" => Time.current.change(usec: 0).iso8601(6), "results" => []
      }
      client = Object.new
      client.define_singleton_method(:web_search!) { |**| response }
      PublicWebResearch.perform!(
        workspace: @workspace, membership: @owner, task:, query: "public status history",
        request_key:, client:
      )
    end
end
