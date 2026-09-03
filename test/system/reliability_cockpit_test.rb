require "application_system_test_case"

class ReliabilityCockpitSystemTest < ApplicationSystemTestCase
  test "a Manager reads all five states and invokes only a confirmed safe recovery" do
    workspace = workspaces(:acme_support)
    owner = memberships(:owner_support)
    manager = create_membership(workspace, "reliability-browser-manager@example.com", :manager)
    inbox = workspace.shared_email_inboxes.create!(
      name: "Failed browser connector", email_address: "failed-browser@example.com",
      credential_key: "failed_browser"
    )
    inbox.inbound_email_deliveries.create!(
      workspace:, source_message_id: "failed-browser@example.com",
      content_sha256: Digest::SHA256.hexdigest("failed-browser"), raw_email: "failed",
      status: :failed, failure_code: "missing_sender", received_at: 2.days.ago,
      processed_at: 2.days.ago
    )
    runtime = workspace.runtime_installations.create!(
      detection_key: Digest::SHA256.hexdigest("browser-unhealthy-runtime"),
      adapter_key: "browser_unhealthy", protocol_version: "v1",
      executable_path: "/opt/navishai/browser-unhealthy", executable_version: "1",
      account_metadata: {}, capabilities: [], minimum_version: "1", maximum_version: "1",
      compatibility_status: "compatible", incompatibility_reason: "",
      health_status: "unhealthy", checked_at: Time.current
    )
    runner_failure = create_retryable_runner_failure(workspace, owner)
    unknown_delivery = create_unknown_email_delivery(workspace, owner)
    memory = workspace.memory_records.create!(
      memory_type: :semantic, scope_kind: :workspace, topic: "browser recovery",
      content: "Authoritative browser source", authority: :source_record, origin_kind: :system,
      source_reference: "test://browser-recovery",
      source_digest: Digest::SHA256.hexdigest("browser-recovery"),
      observed_at: 1.day.ago, valid_from: 1.day.ago, confidence: 1,
      retention_policy: :indefinite
    )
    workspace.memory_index_entries.create!(
      memory_record: memory, status: :failed, attempt_count: 1,
      failure_code: "remote_unavailable", last_attempted_at: 10.minutes.ago
    )
    record_check(workspace, manager, "archive_verification", 1.hour.ago)
    record_check(
      workspace, manager, "backup_verification", 1.hour.ago,
      result: "failed", result_code: "checksum_mismatch"
    )
    record_check(
      workspace, manager, "restore_rehearsal", 1.hour.ago,
      result: "failed", result_code: "verification_failed"
    )
    sign_in(owner.user)

    page.current_window.resize_to(1440, 1000)
    visit workspace_reliability_cockpit_path(workspace)

    assert_selector "h1", text: "Reliability"
    assert_selector ".reliability-key dt", count: 5
    assert_selector ".reliability-item.status-healthy", text: "Archive verification"
    assert_selector ".reliability-item.status-blocked", text: "Memory index"
    assert_selector ".reliability-item.status-unknown", text: "Do not resend"
    assert_selector ".reliability-item.status-blocked", text: "Backup verification"
    assert_selector ".reliability-item.status-blocked", text: "Restore rehearsal"
    assert_selector "#email-#{inbox.id} a", text: "Inspect email"
    assert_selector "#runtime-#{runtime.id} a", text: "Inspect runtime"
    assert_selector "#run-#{runner_failure.id} button", text: "Retry definite failure"
    assert_selector "#queue.status-not-configured", text: "Workspace-specific queue evidence is unavailable because the queue is shared."
    assert_selector "#email-send-#{unknown_delivery.id} a", text: "Investigate exact send"
    assert_no_selector "#email-send-#{unknown_delivery.id} form"
    assert_no_selector "#backup_verification .reliability-action"
    assert_no_selector "#restore_rehearsal .reliability-action"
    if ENV["CAPTURE_M6_VISUAL_PROOF"]
      capture_region(
        Rails.root.join(".amp/in/artifacts/reliability-recovery-controls-desktop.png"),
        from: "#connectors", through: "#data"
      )
      page.current_window.resize_to(320, 844)
      assert_no_horizontal_overflow
      capture_region(
        Rails.root.join(".amp/in/artifacts/reliability-recovery-controls-mobile.png"),
        from: "#connectors", through: "#data"
      )
      page.current_window.resize_to(1440, 1000)
    end
    reset_session!
    sign_in(manager.user)
    visit workspace_reliability_cockpit_path(workspace)
    assert_selector "h1", text: "Reliability"
    if ENV["CAPTURE_RELIABILITY_COCKPIT"]
      page.execute_script("window.scrollTo(0, 0)")
      save_screenshot Rails.root.join(".amp/in/artifacts/reliability-cockpit-desktop.png")
    end

    summary = find("#data > summary")
    summary.send_keys(:enter)
    assert summary.ancestor("details")[:open]
    assert_equal "SUMMARY", page.evaluate_script("document.activeElement.tagName")

    accept_confirm(/authoritative PostgreSQL records/) do
      click_button "Rebuild failed index work"
    end
    assert_text "Queued 1 Memory record for safe reindexing"
    assert_no_button "Rebuild failed index work"

    page.current_window.resize_to(320, 844)
    visit workspace_reliability_cockpit_path(workspace)
    assert_no_horizontal_overflow
    assert_operator find_link("Investigate exact send").rect.height, :>=, 48
    save_screenshot Rails.root.join(".amp/in/artifacts/reliability-cockpit-mobile.png") if
      ENV["CAPTURE_RELIABILITY_COCKPIT"]

    member = create_membership(workspace, "reliability-browser-member@example.com", :member)
    reset_session!
    sign_in(member.user)
    visit workspace_support_cases_path(workspace)
    open_workspace_nav
    assert_no_link "Reliability"
    visit workspace_reliability_cockpit_path(workspace)
    assert_no_selector "h1", text: "Reliability"
    assert_no_text "Workspace state"
  end

  private
    def create_membership(workspace, email, role)
      user = User.create!(email_address: email, password: "password12345", verified_at: Time.current)
      workspace.memberships.create!(user:, role:)
    end

    def create_unknown_email_delivery(workspace, owner)
      support_case = create_support_case(workspace:, membership: owner)
      inbox = workspace.shared_email_inboxes.create!(
        name: "Browser support", email_address: "browser-support@example.com", credential_key: "browser_support"
      )
      thread = workspace.email_threads.create!(
        shared_email_inbox: inbox, conversation: support_case.conversation,
        thread_key: "reliability-browser-thread"
      )
      draft = workspace.email_drafts.create!(
        support_case:, email_thread: thread, conversation: support_case.conversation,
        updated_by: owner.user, body: "Frozen browser message", status: :sending
      )
      workspace.outbound_email_deliveries.create!(
        email_draft: draft, shared_email_inbox: inbox, email_thread: thread,
        conversation: support_case.conversation, actor_membership: owner, actor_user: owner.user,
        idempotency_key: "reliability-browser-unknown", message_id: "reliability-browser@navishai.local",
        from_address: inbox.email_address, to_address: "customer@example.net", subject: "Reply",
        body: draft.body, status: :unknown, failure_code: "unknown_outcome", started_at: 10.minutes.ago
      )
    end

    def create_retryable_runner_failure(workspace, owner)
      install_crew_test_dependencies(workspace:, membership: owner)
      task = CrewWork.create!(
        workspace:, membership: owner, scope: accounts(:acme),
        profile: workspace.agent_profiles.find_by!(role_key: "risk_investigator"),
        title: "Retry definite browser failure", input_context: "Use retained facts.",
        expected_output: "Return a bounded result."
      )
      CrewWork.apply!(
        workspace:, membership: owner, task:, command: :start,
        expected_sequence: task.current_event.sequence_number, attributes: {}
      )
      run = ExecutionLedger.new(workspace:).prepare!(task: task.reload, request_key: "browser-runner-failure")
      ingest_run_event(workspace, run, 1, "run.admitted", {
        workspace_key: workspace.runner_key, task_key: task.task_key, attempt: run.attempt_number
      })
      ingest_run_event(workspace, run, 2, "run.started", {
        adapter: run.selected_adapter_key, scenario: "browser-failure", attempt: run.attempt_number
      })
      ingest_run_event(workspace, run, 3, "run.failed", {
        code: "runner_unavailable", retryable: true
      })
      run.reload
    end

    def ingest_run_event(workspace, run, sequence, event_type, data)
      ExecutionLedger.new(workspace:).ingest!(event: {
        "protocol_version" => RunnerProtocol::VERSION,
        "event_id" => SecureRandom.uuid,
        "run_id" => run.run_key,
        "sequence" => sequence,
        "event_type" => event_type,
        "occurred_at" => (Time.current + sequence.fdiv(1_000_000)).iso8601(6),
        "data" => data.stringify_keys
      })
    end

    def record_check(workspace, membership, kind, checked_at, result: "passed", result_code: "verified")
      OperationalCheck.record!(
        workspace:, membership:, check_kind: kind, result:, result_code:,
        evidence_digest: Digest::SHA256.hexdigest("#{kind}-#{checked_at.to_i}"),
        source_commit: "d" * 40, checked_at:
      )
    end
end
