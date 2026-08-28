require "application_system_test_case"
require "base64"

class GovernedPoliciesSystemTest < ApplicationSystemTestCase
  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
    approve_scripted_runtime(workspace: @workspace, membership: @owner)
    ResolutionContractConfiguration.install_defaults!(workspace: @workspace)
    CrewConfiguration.install_defaults!(workspace: @workspace)
    @profile = @workspace.agent_profiles.find_by!(role_key: "support_investigator")
    @support_case = create_support_case(
      subject: "Governed policy browser case", workspace: @workspace, membership: @owner
    )
    @account = @support_case.conversation.contact.account
  end

  test "an Owner previews named scopes publishes frozen work and rolls back future decisions" do
    sign_in(users(:owner))

    case_proposal = submit_proposal(
      scope_kind: "support_case", subject_id: @support_case.id,
      reason: "Browser case canary", review_policy: "Review when policy flags risk"
    )
    case_preview = preview(case_proposal)
    within "#preview-#{case_preview.id}" do
      assert_text "Current"
      assert_text "Proposed"
      assert_text "Quality review"
      assert_text "Exact typed facts"
      find(".policy-facts summary").click
      assert_text "subject.id"
      assert_text "integer"
      assert_text "On policy flag"
    end
    case_publication = publish(case_proposal)

    account_proposal = submit_proposal(
      scope_kind: "account", subject_id: @account.id, reason: "Browser Account canary"
    )
    account_preview = preview(account_proposal)
    within "#preview-#{account_preview.id}" do
      assert_text "No change"
      assert_text "No policy decision changes"
    end
    account_publication = publish(account_proposal)

    profile_proposal = submit_proposal(
      scope_kind: "agent_profile", subject_id: @profile.id, reason: "Browser profile canary"
    )
    profile_preview = preview(profile_proposal)
    within "#preview-#{profile_preview.id}" do
      assert_text "No change"
      assert_text "Exact typed facts"
    end
    profile_publication = publish(profile_proposal)

    assert_text "3 active"
    [ case_publication, account_publication, profile_publication ].each do |publication|
      assert_selector "#publication-#{publication.id}"
    end
    if ENV["CAPTURE_M6_VISUAL_PROOF"]
      visit workspace_governed_policy_path(@workspace)
      page.current_window.resize_to(1440, 1000)
      capture_region(
        Rails.root.join(".amp/in/artifacts/governed-policy-canary-scope-desktop.png"),
        from: ".policy-active .section-heading-row", through: "#publication-#{case_publication.id}"
      )
      page.current_window.resize_to(320, 844)
      assert_no_horizontal_overflow
      capture_region(
        Rails.root.join(".amp/in/artifacts/governed-policy-canary-scope-mobile.png"),
        from: ".policy-active .section-heading-row", through: "#publication-#{case_publication.id}"
      )
      page.current_window.resize_to(1440, 1000)
    end

    task = CrewWork.create!(
      workspace: @workspace, membership: @owner, scope: @support_case, profile: @profile,
      title: "Browser governed run", input_context: "Use retained facts.",
      expected_output: "Return a bounded result."
    )
    ExecutionLedger.new(workspace: @workspace).prepare!(task:, request_key: "browser-governed-run")
    outside_account = @workspace.accounts.create!(name: "Outside canary account")
    outside_contact = @workspace.contacts.create!(account: outside_account, name: "Outside canary contact")
    outside_case = create_support_case(
      subject: "Outside all named policy scopes", workspace: @workspace, membership: @owner,
      contact: outside_contact
    )
    outside_profile = @workspace.agent_profiles.find_by!(role_key: "resolution_drafter")
    outside_task = CrewWork.create!(
      workspace: @workspace, membership: @owner, scope: outside_case, profile: outside_profile,
      title: "Browser baseline run", input_context: "Use retained facts.",
      expected_output: "Return a bounded result."
    )
    ExecutionLedger.new(workspace: @workspace).prepare!(
      task: outside_task, request_key: "browser-baseline-run"
    )

    visit workspace_support_case_crew_task_path(@workspace, @support_case, task)
    assert_text "Explicit policy canary active"
    assert_text "named support case selection"
    visit workspace_support_case_crew_task_path(@workspace, outside_case, outside_task)
    assert_no_text "Explicit policy canary active"
    assert_no_text "Policy rollback applied"

    visit workspace_governed_policy_path(@workspace)
    within "#publication-#{case_publication.id}" do
      fill_in "Rollback reason", with: "Browser canary complete"
      click_button "Roll back future decisions"
    end
    assert_text "Rollback recorded for future decisions"
    assert_text "Rollback · Support case"

    page.current_window.resize_to(320, 1_500)
    case_preview_card = find("#preview-#{case_preview.id}")
    facts = case_preview_card.find(".policy-facts")
    facts.find("summary").click unless page.evaluate_script("arguments[0].open", facts)
    2.times do
      page.current_window.resize_to(320, [ case_preview_card.rect.height.ceil + 300, 5_000 ].min)
    end
    scroll_to case_preview_card, align: :top
    assert_no_horizontal_overflow
    digest = case_preview_card.find(".policy-digests code", match: :first)
    assert_operator digest.rect.x + digest.rect.width, :<=, page.evaluate_script("window.innerWidth")
    assert_operator find_button("Roll back future decisions", match: :first).rect.height, :>=, 44
    case_preview_card.find(".policy-diff > summary", match: :first).send_keys(:tab)
    assert page.evaluate_script("document.activeElement.matches('button, input, select, textarea, summary, a')")
    page.driver.browser.execute_cdp(
      "Emulation.setEmulatedMedia",
      media: "screen", features: [ { name: "prefers-reduced-motion", value: "reduce" } ]
    )
    assert_equal "0s",
      find(".policy-record summary", match: :first).style("transition-duration").fetch("transition-duration")
    assert_no_csp_violations
    capture_mobile_card(case_preview_card) if ENV["CAPTURE_POLICIES"]

    page.current_window.resize_to(1440, 1000)
    page.execute_script("window.scrollTo(0, 0)")
    2.times do
      page.current_window.resize_to(
        1440, [ page.evaluate_script("document.documentElement.scrollHeight") + 300, 10_000 ].min
      )
    end
    save_screenshot Rails.root.join(".amp/in/artifacts/governed-policy-desktop.png") if ENV["CAPTURE_POLICIES"]
  end

  test "stale previews and lower roles fail closed without policy disclosure" do
    sign_in(users(:owner))
    proposal = submit_proposal(
      scope_kind: "support_case", subject_id: @support_case.id, reason: "Stale browser preview"
    )
    preview(proposal)
    runtime_installations(:acme_scripted).update!(
      approved: false, approved_by_membership: nil, approved_by_user: nil, approved_at: nil
    )
    within "#proposal-#{proposal.id}" do
      click_button "Publish to this explicit canary"
    end
    assert_text "Policy was not changed"
    assert_text "stale"
    assert_empty proposal.publications

    manager = User.create!(
      email_address: "policy-system-manager@example.com", password: "password12345", verified_at: Time.current
    )
    @workspace.memberships.create!(user: manager, role: :manager)
    Capybara.reset_session!
    sign_in(manager)
    visit workspace_governed_policy_path(@workspace)
    assert_no_text "Governed policy change"
    assert_no_text proposal.reason
  end

  private
    def submit_proposal(scope_kind:, subject_id:, reason:, review_policy: "Review every result")
      visit workspace_governed_policy_path(@workspace)
      card = find(".policy-profile", text: @profile.name, match: :first)
      card.find("summary").click unless page.evaluate_script("arguments[0].open", card)
      within card do
        find("input[type='radio'][value='#{scope_kind}']").choose
        find("input[name='governed_policy[#{scope_kind}_ids][]'][value='#{subject_id}']").check
        select review_policy, from: "Quality review requirement"
        fill_in "Reason", with: reason
        click_button "Save immutable proposal"
      end
      assert_text "Policy proposal saved"
      @workspace.governed_policy_proposals.order(:id).last
    end

    def preview(proposal)
      within "#proposal-#{proposal.id}" do
        click_button "Preview retained facts"
      end
      assert_text "Preview complete"
      proposal.previews.reload.first
    end

    def publish(proposal)
      within "#proposal-#{proposal.id}" do
        click_button "Publish to this explicit canary"
      end
      assert_text "Explicit canary published"
      proposal.publications.reload.first
    end

    def sign_in(user)
      visit new_session_path
      fill_in "Email address", with: user.email_address
      fill_in "Password", with: "password12345"
      click_on "Sign in"
      assert_selector "h1", text: "Choose a workspace", wait: 6
    end

    def capture_mobile_card(card)
      clip = page.evaluate_script(<<~JAVASCRIPT, card)
        (() => {
          const rect = arguments[0].getBoundingClientRect();
          const lastDiff = arguments[0].querySelector('.policy-diff:last-of-type').getBoundingClientRect();
          return { x: 0, y: rect.top + window.scrollY, width: window.innerWidth,
            height: lastDiff.bottom - rect.top + 1, scale: 1 };
        })()
      JAVASCRIPT
      screenshot = page.driver.browser.execute_cdp(
        "Page.captureScreenshot", format: "png", captureBeyondViewport: true, clip:
      )
      File.binwrite(
        Rails.root.join(".amp/in/artifacts/governed-policy-mobile.png"),
        Base64.strict_decode64(screenshot.fetch("data"))
      )
    end
end
