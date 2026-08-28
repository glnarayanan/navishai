require "application_system_test_case"

class AccountDossierTest < ApplicationSystemTestCase
  setup do
    @workspace = workspaces(:acme_support)
    @account = accounts(:acme)
    @owner = memberships(:owner_support)
  end

  test "owner reviews full conflicting source history and resolves a recorded identity candidate" do
    page.current_window.resize_to(1440, 1000)
    first_case = create_support_case(subject: "Recurring access failure")
    second_case = create_support_case(subject: "Access failure returned")
    tag = CaseWorkflow.create_tag!(workspace: @workspace, membership: @owner, name: "Recurring access")
    CaseWorkflow.tag!(workspace: @workspace, support_case: first_case, membership: @owner, tag:)
    CaseWorkflow.tag!(workspace: @workspace, support_case: second_case, membership: @owner, tag:)
    AccountHealth.recalculate!(
      workspace: @workspace, account: @account, trigger_kind: "human_request", membership: @owner
    )
    original = create_memory("support-window", "Support ends at 18:00 UTC.")
    create_memory("support-window", "Support ends at 19:00 UTC.")
    correction = MemoryGovernance.propose_correction!(
      workspace: @workspace, membership: @owner, memory_record: original,
      content: "Support ends at 18:30 UTC.", confidence: 1,
      retention_policy: :indefinite, proposed_at: Time.current
    ).published_memory_record
    create_memory("long-context", "long-source-value-" * 300)
    stale = create_memory("legacy-plan", "Legacy plan was active.", valid_until: 1.hour.ago)
    deleted = create_memory("deleted-note", "Removed customer note.")
    MemoryGovernance.delete!(
      workspace: @workspace, membership: @owner, memory_record: deleted, reason: "Customer requested removal"
    )
    assert_not stale.eligible_at?(Time.current)
    identity = ambiguous_identity
    sign_in_in_browser(users(:owner))

    visit workspace_account_path(@workspace, @account)

    assert_selector "h2", text: "Account dossier"
    assert_text "Current facts lead."
    assert_text "Conflict retained"
    assert_text "Stale"
    assert_text "Deleted"
    assert_text "Recurring access"
    assert_text correction.content
    assert_text "Corrects"
    assert_text "Current health facts"
    assert_link "Inspect record and correction history"
    assert_button "Use this match", count: 2
    assert_equal 0, horizontal_overflow

    find("body").send_keys(:tab)
    assert_equal "Skip to content", page.evaluate_script("document.activeElement.textContent")
    click_button "Use this match", match: :first
    assert_text "Source identity resolved."
    assert identity.reload.matched?
    save_screenshot Rails.root.join(".amp/in/artifacts/account-dossier-desktop.png") if ENV["CAPTURE_ACCOUNT_DOSSIER"]
    if ENV["CAPTURE_M6_VISUAL_PROOF"]
      visit workspace_account_path(@workspace, @account)
      page.current_window.resize_to(1440, 1000)
      assert_dossier_visual_evidence(correction)
      capture_viewport(
        Rails.root.join(".amp/in/artifacts/account-dossier-correction-desktop.png"),
        find(".dossier-memory-group", text: "support-window"), height: 1_000
      )
      capture_viewport(
        Rails.root.join(".amp/in/artifacts/account-dossier-current-state-desktop.png"),
        find("[aria-labelledby='dossier-health-title']").ancestor(".dossier-grid"), height: 1_000
      )
      page.current_window.resize_to(320, 844)
      visit workspace_account_path(@workspace, @account)
      assert_no_horizontal_overflow
      assert_dossier_visual_evidence(correction)
      capture_viewport(
        Rails.root.join(".amp/in/artifacts/account-dossier-correction-mobile.png"),
        find(".dossier-memory-group", text: "support-window"), height: 1_600
      )
      capture_viewport(
        Rails.root.join(".amp/in/artifacts/account-dossier-current-state-mobile.png"),
        find("[aria-labelledby='dossier-health-title']").ancestor(".dossier-grid"), height: 1_800
      )
    end
  end

  test "mobile case context leads to the full dossier without overflow" do
    page.current_window.resize_to(320, 760)
    support_case = create_support_case(subject: "Mobile dossier context")
    add_inbound_message(support_case, body: "Please retain this mobile Account context.")
    sign_in_in_browser(users(:owner))

    visit workspace_support_case_path(@workspace, support_case)

    assert_selector ".account-context-card", text: "Account context"
    assert_text "Next human action"
    assert_equal 0, horizontal_overflow
    click_link "Full dossier"

    assert_selector "h2", text: "Account dossier"
    assert_text "Please retain this mobile Account context."
    assert_text "conversation-message://"
    assert_text "No deterministic health snapshot exists"
    assert_equal 0, horizontal_overflow
    assert_operator find_link("Open source record").evaluate_script("this.getBoundingClientRect().height"), :>=, 48
    save_screenshot Rails.root.join(".amp/in/artifacts/account-dossier-mobile.png") if ENV["CAPTURE_ACCOUNT_DOSSIER"]
  end

  test "viewer gets an empty dossier with governed memory and review controls denied" do
    empty_account = @workspace.accounts.create!(name: "Unobserved Account")
    viewer = User.create!(email_address: "empty-dossier-viewer@example.com", password: "password12345", verified_at: Time.current)
    @workspace.memberships.create!(user: viewer, role: :viewer)
    sign_in_in_browser(viewer)

    visit workspace_account_path(@workspace, empty_account)

    assert_selector "h2", text: "Account dossier"
    assert_text "No external source identity is linked yet."
    assert_text "No imported relationship facts are recorded."
    assert_text "Your current role cannot inspect governed memory."
    assert_text "No retained customer conversation is linked."
    assert_text "No deterministic health snapshot exists."
    assert_text "No Account or case work is recorded."
    assert_no_button "Use this match"
  end

  private
    def assert_dossier_visual_evidence(correction)
      assert_selector "#dossier-memory-title", text: "Governed context"
      within find(".dossier-memory-group", text: "support-window") do
        assert_text "Conflict retained"
        assert_text "Effective value"
        assert_text correction.content
        assert_text "Human correction"
        assert_text "Corrects"
      end
      assert_selector "#dossier-health-title", text: "Current health facts"
      assert_selector "#dossier-work-title", text: "Commitments, decisions, and work"
      assert_text "No Account or case work is recorded."
    end

    def create_memory(topic, content, valid_until: nil)
      @workspace.memory_records.create!(
        memory_type: :profile, scope_kind: :account, account: @account, topic:, content:,
        authority: :source_record, origin_kind: :system, source_reference: "test://#{topic}/#{SecureRandom.hex(4)}",
        source_digest: Digest::SHA256.hexdigest(content), observed_at: 2.hours.ago, valid_from: 2.hours.ago,
        valid_until:, confidence: 0.9, retention_policy: :indefinite
      )
    end

    def ambiguous_identity
      duplicate = contacts(:alice_duplicate)
      matched_identity = @workspace.source_identities.create!(
        entity_kind: :contact, source_namespace: "manual_import", source_record_type: :contact,
        source_record_id: "dossier-duplicate", status: :matched, contact: duplicate,
        resolution_method: :created, resolved_at: Time.current
      )
      matched_identity.source_identity_keys.create!(
        workspace: @workspace, kind: :email, normalized_value: "alice@example.com"
      )
      SourceIdentityResolver.resolve!(
        workspace: @workspace, entity_kind: :contact, source_namespace: "intercom:primary",
        source_record_type: :contact, source_record_id: "dossier-ambiguous",
        keys: { email: "alice@example.com" }
      ).source_identity
    end

    def sign_in_in_browser(user)
      visit new_session_path
      fill_in "Email address", with: user.email_address
      fill_in "Password", with: "password12345"
      click_button "Sign in"
      assert_selector "h1", text: "Choose a workspace", wait: 6
    end

    def horizontal_overflow
      page.evaluate_script("Math.max(0, document.documentElement.scrollWidth - window.innerWidth)")
    end
end
