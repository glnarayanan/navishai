require "application_system_test_case"

class SupportQualitySystemTest < ApplicationSystemTestCase
  test "members read live quality counts and case links on desktop and 320px" do
    workspace = workspaces(:acme_support)
    owner = memberships(:owner_support)
    calendar = ServiceCalendar.create!(
      workspace:, name: "Quality browser hours", time_zone: "UTC",
      weekly_hours: %w[monday tuesday wednesday thursday friday].index_with { [ [ "09:00", "17:00" ] ] }
    )
    SlaPolicy.create!(
      workspace:, service_calendar: calendar, name: "Quality browser normal",
      priority: :normal, first_response_minutes: 120, resolution_minutes: 480, warning_percent: 75
    )
    support_case = create_support_case(subject: "Browser SLA breach", workspace:, membership: owner)
    support_case.case_sla.update!(first_response_status: "breached")
    sign_in(owner.user)

    page.current_window.resize_to(1440, 1000)
    visit workspace_support_quality_path(workspace)

    assert_selector "h1", text: "Support quality"
    assert_selector ".nav-label", text: "Quality"
    assert_selector "[data-metric=open_cases] strong", text: "1"
    assert_selector "[data-metric=first_response_breaches] strong", text: "1"
    assert_text "Work is open"
    click_link "Browser SLA breach"
    assert_selector "h1", text: "Browser SLA breach"

    visit workspace_support_quality_path(workspace)
    page.current_window.resize_to(320, 844)
    assert_no_horizontal_overflow
    assert_no_csp_violations
    assert_selector "h1", text: "Support quality"
    assert_selector ".quality-list a", text: "Browser SLA breach"
  end
end
