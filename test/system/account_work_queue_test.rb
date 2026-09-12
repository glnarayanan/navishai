require "application_system_test_case"

class AccountWorkQueueTest < ApplicationSystemTestCase
  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
    CrewConfiguration.install_defaults!(workspace: @workspace)
    @workspace.accounts.create!(name: "Unscored Queue #{SecureRandom.hex(4)}")
    AccountDataImport.import_api!(workspace: @workspace, membership: @owner, rows: [ {
      source_id: "browser-queue-renewal", observed_at: Time.current.iso8601,
      account_name: "Approaching Renewal Queue",
      renewal_on: 12.days.from_now.to_date.iso8601, active_users: 90, licensed_seats: 100
    } ])
    @renewal = @workspace.accounts.find_by!(name: "Approaching Renewal Queue")
    sign_in(@owner.user)
  end

  test "fixed account work views keep shareable filters and open the matching record" do
    page.current_window.resize_to(1440, 1000)
    visit workspace_accounts_path(@workspace)

    assert_selector "h1", text: "Accounts"
    assert_selector ".account-work-filter[aria-current=page]", text: /Needs attention/
    assert_selector ".account-work-count", minimum: 6
    assert_no_text "Approve intervention"
    assert_no_text "Record human completion"

    find(".account-work-filter", text: /Renewal approaching/).click
    assert_current_path workspace_accounts_path(@workspace, view: "renewal_approaching")
    assert_selector ".account-work-filter[aria-current=page]", text: /Renewal approaching/
    assert_text "Approaching Renewal Queue"
    assert_selector ".account-work-reason", text: "Renewal approaching"

    click_link "Approaching Renewal Queue"
    assert_text "Deterministic signals"
    click_link "All accounts"
    assert_current_path workspace_accounts_path(@workspace, view: "renewal_approaching")
    assert_selector ".account-work-filter[aria-current=page]", text: /Renewal approaching/

    find(".account-work-filter", text: /^Overdue/).click
    assert_text "No overdue interventions"
    assert_text "Proposed or approved follow-ups whose target date has passed appear here."

    find(".account-work-filter", text: /All accounts/).click
    assert_current_path workspace_accounts_path(@workspace, view: "all_accounts")
    long_name = "Northwind Extremely Long Cooperative Account Name For Wrap #{SecureRandom.hex(3)}"
    @workspace.accounts.create!(name: long_name)
    visit workspace_accounts_path(@workspace, view: "all_accounts")
    assert_text long_name

    filter = find(".account-work-filter", text: /Needs attention/)
    filter.send_keys(:tab)
    assert_operator filter.rect.height, :>=, 44

    page.current_window.resize_to(390, 844)
    visit workspace_accounts_path(@workspace, view: "all_accounts")
    assert_text long_name
    assert_no_horizontal_overflow

    page.current_window.resize_to(320, 844)
    visit workspace_accounts_path(@workspace, view: "needs_attention")
    assert_selector ".account-work-filter[aria-current=page]", text: /Needs attention/
    assert_no_horizontal_overflow
    assert_no_csp_violations
  end

  test "a viewer can read the queue and cannot import" do
    viewer = User.create!(
      email_address: "queue-viewer-#{SecureRandom.hex(4)}@example.com",
      password: "password12345", verified_at: Time.current
    )
    @workspace.memberships.create!(user: viewer, role: :viewer)
    Capybara.reset_sessions!
    sign_in(viewer)
    visit workspace_accounts_path(@workspace)

    assert_selector ".account-work-filters"
    assert_no_text "Import account data"
    click_link "All accounts", href: workspace_accounts_path(@workspace, view: "all_accounts")
    assert_text "Acme Customer"
    assert_no_text "Approve intervention"
  end
end
