require "application_system_test_case"

class CaseQueueAndWorkspaceTest < ApplicationSystemTestCase
  test "owner works a case in the desktop queue and workspace" do
    page.current_window.resize_to(1440, 1000)
    support_case = create_support_case
    add_inbound_message(support_case)
    sign_in_in_browser(users(:owner))

    click_link "Acme Support"
    assert_selector "h2", text: "Case queue"
    click_link "Cannot sign in", match: :first

    assert_selector "h1", text: "Cannot sign in"
    assert_text "I still cannot access my account."
    assert_text "Alice Example"
    assert_text "alice@example.com"
    assert_text "acme.example"
    refute_button "Reply"
    refute_button "Send"

    positions = page.evaluate_script(<<~JS)
      [document.querySelector('.queue-rail'), document.querySelector('.conversation-thread'), document.querySelector('.case-context')]
        .map((element) => element.getBoundingClientRect().left)
    JS
    assert_operator positions[0], :<, positions[1]
    assert_operator positions[1], :<, positions[2]

    select "Triaged", from: "Move to"
    fill_in "Reason", with: "Initial review complete"
    click_button "Update status"
    assert_text "Case status updated."
    assert_text "Triaged"

    find("summary", text: "Priority and assignment").click
    select "High", from: "Priority"
    within find("form[action$='/priority']") do
      click_button "Save"
    end
    assert_text "Priority updated."

    find("summary", text: "Priority and assignment").click
    select users(:owner).email_address, from: "Assignee"
    within find("form[action$='/assignment']") do
      click_button "Save"
    end
    assert_text "Assignment updated."

    find("summary", text: "Tags").click
    fill_in "Create tag", with: "Access"
    click_button "Create"
    assert_text "Tag created and added."
    assert_text "Access"

    find("summary", text: "Private notes").click
    fill_in "Add a private note", with: "Check the identity provider logs."
    click_button "Add note"
    assert_text "Private note added."
    assert_text "Check the identity provider logs."
    save_screenshot Rails.root.join(".amp/in/artifacts/case-workspace-desktop.png") if ENV["CAPTURE_CASE_WORKSPACE"]
  end

  test "selected case has one next action and one selected queue row" do
    page.current_window.resize_to(1440, 1000)
    support_case = create_support_case
    add_inbound_message(support_case)
    other = create_support_case(subject: "Invoice webhook retry")
    add_inbound_message(other, body: "The invoice webhook still returns 401.")
    sign_in_in_browser(users(:owner))

    click_link "Acme Support"
    click_link "Cannot sign in", match: :first

    assert_equal 1, page.all("h2", text: "Next action", visible: true).size
    assert_selector ".decision-next-rail", visible: true
    assert_no_selector ".decision-next-mobile", visible: true
    assert_selector ".queue-rail .case-row[aria-current='page']", text: "Cannot sign in", count: 1
    assert_selector ".queue-rail .case-row", text: "Invoice webhook retry"

    selected, other_shadow, other_background, selected_background = page.evaluate_script(<<~JS)
      const rows = Array.from(document.querySelectorAll('.queue-rail .case-row'))
      const selected = rows.find((row) => row.getAttribute('aria-current') === 'page')
      const other = rows.find((row) => row.getAttribute('aria-current') !== 'page')
      return [
        rows.filter((row) => row.getAttribute('aria-current') === 'page').length,
        getComputedStyle(other).boxShadow,
        getComputedStyle(other).backgroundColor,
        getComputedStyle(selected).backgroundColor
      ]
    JS
    assert_equal 1, selected
    assert_match(/inset/i, page.evaluate_script("getComputedStyle(document.querySelector('.queue-rail .case-row[aria-current=\"page\"]')).boxShadow"))
    refute_match(/inset/i, other_shadow)
    refute_equal selected_background, other_background
  end

  test "mobile case workspace keeps the thread before context without overflow" do
    page.current_window.resize_to(390, 844)
    support_case = create_support_case
    add_inbound_message(support_case)
    sign_in_in_browser(users(:owner))
    visit workspace_support_cases_path(support_case.workspace)

    click_link "Cannot sign in", match: :first

    assert_link "Back to case queue"
    positions = page.evaluate_script(<<~JS)
      [document.querySelector('.conversation-thread'), document.querySelector('.case-context')]
        .map((element) => element.getBoundingClientRect().top)
    JS
    assert_operator positions[0], :<, positions[1]
    assert_equal 0, page.evaluate_script("Math.max(0, document.documentElement.scrollWidth - window.innerWidth)")
    assert_operator find_field("Reason").evaluate_script("this.getBoundingClientRect().height"), :>=, 48

    find("summary", text: "Private notes").click
    fill_in "Add a private note", with: "Mobile note"
    click_button "Add note"
    assert_text "Mobile note"
    assert_equal 0, page.evaluate_script("Math.max(0, document.documentElement.scrollWidth - window.innerWidth)")
    save_screenshot Rails.root.join(".amp/in/artifacts/case-workspace-mobile.png") if ENV["CAPTURE_CASE_WORKSPACE"]
  end

  test "keyboard validation focuses the case error" do
    page.current_window.resize_to(1440, 1000)
    support_case = create_support_case
    sign_in_in_browser(users(:owner))
    visit workspace_support_case_path(support_case.workspace, support_case)

    find("body").send_keys(:tab)
    assert_equal "Skip to content", page.evaluate_script("document.activeElement.textContent")

    select "Triaged", from: "Move to"
    page.execute_script("document.querySelector('input[name=reason]').removeAttribute('required')")
    click_button "Update status"

    assert_selector ".command-error", text: /reason is required/i
    assert_equal "command-error", page.evaluate_script("document.activeElement.classList[1]")
    assert_select_value "Move to", "triaged"
  end

  test "viewer has read-only access and an empty workspace teaches the queue" do
    page.current_window.resize_to(1440, 1000)
    support_case = create_support_case
    add_inbound_message(support_case)
    viewer = User.create!(email_address: "browser-viewer@example.com", password: "password12345", verified_at: Time.current)
    Membership.create!(workspace: support_case.workspace, user: viewer, role: :viewer)
    sign_in_in_browser(viewer)

    visit workspace_support_case_path(support_case.workspace, support_case)
    assert_text "Read-only access"
    find("summary", text: "Private notes").click
    assert_text "Private — staff only"
    refute_field "Reason"
    refute_field "Add a private note"

    click_button "Sign out"
    sign_in_in_browser(users(:outsider))
    click_link "Beta Support"
    assert_text "No cases in the queue"
    open_workspace_nav
    assert_link "Workspaces", visible: true
  end

  private
    def sign_in_in_browser(user)
      visit new_session_path
      fill_in "Email address", with: user.email_address
      fill_in "Password", with: "password12345"
      click_button "Sign in"
      assert_selector "h1", text: "Choose a workspace", wait: 6
    end

    def assert_select_value(label, value)
      assert_equal value, find_field(label).value
    end
end
