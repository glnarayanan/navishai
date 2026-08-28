require "application_system_test_case"

class ReliabilityCockpitSystemTest < ApplicationSystemTestCase
  test "a Manager reads all five states and invokes only a confirmed safe recovery" do
    workspace = workspaces(:acme_support)
    owner = memberships(:owner_support)
    manager = create_membership(workspace, "reliability-browser-manager@example.com", :manager)
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
    record_check(workspace, manager, "backup_verification", 31.days.ago)
    sign_in(manager.user)

    page.current_window.resize_to(1440, 1000)
    visit workspace_reliability_cockpit_path(workspace)

    assert_selector "h1", text: "Reliability"
    assert_selector ".reliability-key dt", count: 5
    assert_selector ".reliability-item.status-healthy", text: "Archive verification"
    assert_selector ".reliability-item.status-attention", text: "Backup verification"
    assert_selector ".reliability-item.status-blocked", text: "Memory index"
    assert_selector ".reliability-item.status-unknown", text: "Do not resend"
    assert_selector ".reliability-item.status-not-configured", text: "Restore rehearsal"
    assert_selector "#queue.status-not-configured", text: "Workspace-specific queue evidence is unavailable because the queue is shared."
    assert_selector "#email-send-#{unknown_delivery.id} a", text: "Investigate exact send"
    assert_no_selector "#email-send-#{unknown_delivery.id} form"
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
    def sign_in(user)
      visit new_session_path
      fill_in "Email address", with: user.email_address
      fill_in "Password", with: "password12345"
      click_button "Sign in"
      assert_selector "h1", text: "Choose a workspace", wait: 6
    end

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

    def record_check(workspace, membership, kind, checked_at)
      OperationalCheck.record!(
        workspace:, membership:, check_kind: kind, result: "passed", result_code: "verified",
        evidence_digest: Digest::SHA256.hexdigest("#{kind}-#{checked_at.to_i}"),
        source_commit: "d" * 40, checked_at:
      )
    end
end
