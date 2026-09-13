require "test_helper"

class SupportQualityReadoutTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
  end

  test "an empty workspace reports zeros and no attention" do
    readout = SupportQualityReadout.build(workspace: @workspace)

    assert_equal 0, metric(readout, "open_cases").value
    assert_equal 0, metric(readout, "first_response_breaches").value
    assert_equal 0, metric(readout, "resolution_breaches").value
    assert_equal 0, metric(readout, "reopened_90d").value
    assert_equal 0, metric(readout, "without_proof_90d").value
    assert_equal 0, metric(readout, "proofed_90d").value
    assert_equal 0, metric(readout, "blocked_drafts").value
    assert_not readout.attention?
    assert_empty readout.breached_cases
    assert_empty readout.unproofed_accounts
    assert_empty readout.blocked_drafts
  end

  test "counts an open case without treating volume as attention" do
    create_support_case(subject: "Open quality case")

    readout = SupportQualityReadout.build(workspace: @workspace)

    assert_equal 1, metric(readout, "open_cases").value
    assert_equal "neutral", metric(readout, "open_cases").tone
    assert_not readout.attention?
  end

  test "counts first-response and resolution breaches on open cases" do
    install_sla_policy
    support_case = create_support_case(subject: "Breached quality case")
    support_case.case_sla.update!(first_response_status: "breached", resolution_status: "breached")

    readout = SupportQualityReadout.build(workspace: @workspace)

    assert_equal 1, metric(readout, "first_response_breaches").value
    assert_equal 1, metric(readout, "resolution_breaches").value
    assert_equal "attention", metric(readout, "first_response_breaches").tone
    assert readout.attention?
    row = readout.breached_cases.sole
    assert_equal "Breached quality case", row.title
    assert_match(/first response breached/, row.detail)
    assert_match(/resolution breached/, row.detail)
    assert_equal [ @workspace, support_case ], row.path
  end

  test "sums latest unproofed and reopen signals and lists unproofed accounts" do
    event_time = Time.current.change(usec: 0)
    account = accounts(:acme)
    contact = @workspace.contacts.create!(account:, name: "Quality lifecycle contact")
    first_case = create_support_case(subject: "Quality outage one", contact:)
    second_case = create_support_case(subject: "Quality outage two", contact:)
    first_case.status_changes.create!(
      workspace: @workspace, from_status: "resolved", to_status: "investigating",
      actor_kind: "system", source: "integration", reason: "Customer replied", occurred_at: event_time - 2.days
    )
    [ first_case, second_case ].each do |support_case|
      support_case.status_changes.create!(
        workspace: @workspace, from_status: "awaiting_human_review", to_status: "resolved",
        actor_kind: "user", actor: @owner.user, source: "web", reason: "Human confirmed",
        occurred_at: event_time - 1.day
      )
    end
    create_draft_artifact(
      workspace: @workspace, support_case: first_case, membership: @owner,
      body: "Proofed quality resolution", result_state: "complete"
    )
    AccountHealth.recalculate!(
      workspace: @workspace, account:, trigger_kind: "human_request", membership: @owner,
      at: 1.second.from_now.change(usec: 0)
    )

    readout = SupportQualityReadout.build(workspace: @workspace)

    assert_equal 1, metric(readout, "reopened_90d").value
    assert_equal 1, metric(readout, "without_proof_90d").value
    assert_equal 1, metric(readout, "proofed_90d").value
    assert_equal "healthy", metric(readout, "proofed_90d").tone
    assert readout.attention?
    row = readout.unproofed_accounts.sole
    assert_equal account.name, row.title
    assert_match(/1 resolution without contract proof/, row.detail)
    assert_equal [ @workspace, account ], row.path
  end

  test "lists current blocked resolution drafts and ignores complete drafts" do
    support_case = create_support_case(subject: "Blocked quality draft")
    create_draft_artifact(
      workspace: @workspace, support_case:, membership: @owner,
      body: "Blocked quality answer", result_state: "blocked"
    )
    complete_case = create_support_case(subject: "Complete quality draft")
    create_draft_artifact(
      workspace: @workspace, support_case: complete_case, membership: @owner,
      body: "Complete quality answer", result_state: "complete"
    )

    readout = SupportQualityReadout.build(workspace: @workspace)

    assert_equal 1, metric(readout, "blocked_drafts").value
    row = readout.blocked_drafts.sole
    assert_equal "Blocked quality draft", row.title
    assert_match(/blocked/i, row.detail)
    assert_equal [ @workspace, support_case ], row.path
  end

  test "ignores foreign Workspace cases, SLA clocks, health, and drafts" do
    install_sla_policy
    local_case = create_support_case(subject: "Local quality case")
    local_case.case_sla.update!(first_response_status: "breached")

    foreign = workspaces(:beta_support)
    foreign_owner = memberships(:outsider_beta)
    calendar = ServiceCalendar.create!(
      workspace: foreign, name: "Foreign hours", time_zone: "UTC",
      weekly_hours: %w[monday tuesday wednesday thursday friday].index_with { [ [ "09:00", "17:00" ] ] }
    )
    SlaPolicy.create!(
      workspace: foreign, service_calendar: calendar, name: "Foreign normal",
      priority: :normal, first_response_minutes: 120, resolution_minutes: 480, warning_percent: 75
    )
    foreign_case = create_support_case(
      subject: "Foreign quality case", workspace: foreign, contact: contacts(:bob), membership: foreign_owner
    )
    foreign_case.case_sla.update!(first_response_status: "breached", resolution_status: "breached")
    create_draft_artifact(
      workspace: foreign, support_case: foreign_case, membership: foreign_owner,
      body: "Foreign blocked draft", result_state: "blocked"
    )
    AccountHealth.recalculate!(
      workspace: foreign, account: accounts(:beta), trigger_kind: "human_request",
      membership: foreign_owner
    )

    readout = SupportQualityReadout.build(workspace: @workspace)

    assert_equal 1, metric(readout, "open_cases").value
    assert_equal 1, metric(readout, "first_response_breaches").value
    assert_equal 0, metric(readout, "resolution_breaches").value
    assert_equal 0, metric(readout, "blocked_drafts").value
    assert_equal [ "Local quality case" ], readout.breached_cases.map(&:title)
    assert_empty readout.unproofed_accounts
    assert_empty readout.blocked_drafts
  end

  private
    def metric(readout, key)
      readout.metrics.find { |item| item.key == key }
    end

    def install_sla_policy
      calendar = ServiceCalendar.create!(
        workspace: @workspace, name: "Quality hours", time_zone: "UTC",
        weekly_hours: %w[monday tuesday wednesday thursday friday].index_with { [ [ "09:00", "17:00" ] ] }
      )
      SlaPolicy.create!(
        workspace: @workspace, service_calendar: calendar, name: "Quality normal",
        priority: :normal, first_response_minutes: 120, resolution_minutes: 480, warning_percent: 75
      )
    end
end
