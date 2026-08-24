require "test_helper"

class SlaTenancyTest < ActiveSupport::TestCase
  setup do
    @acme = workspaces(:acme_support)
    @beta = workspaces(:beta_support)
    @calendar = ServiceCalendar.create!(
      workspace: @acme,
      name: "Support hours",
      time_zone: "UTC",
      weekly_hours: { "monday" => [ [ "09:00", "17:00" ] ] }
    )
    @policy = SlaPolicy.create!(
      workspace: @acme,
      service_calendar: @calendar,
      name: "Normal priority",
      priority: :normal,
      first_response_minutes: 60,
      resolution_minutes: 240,
      warning_percent: 80
    )
    @case_sla = ConversationThread.start!(
      workspace: @acme,
      contact: contacts(:alice),
      membership: memberships(:owner_support),
      subject: "Tenant constraints"
    ).support_case.case_sla
    @beta_case = create_support_case(
      workspace: @beta,
      contact: contacts(:bob),
      membership: memberships(:outsider_beta)
    )
  end

  test "holiday composite foreign key rejects a cross-workspace calendar" do
    assert_raises(ActiveRecord::InvalidForeignKey) do
      ServiceCalendarHoliday.insert_all!([ {
        workspace_id: @beta.id, service_calendar_id: @calendar.id,
        date: Date.new(2026, 8, 24), name: "Wrong tenant",
        created_at: Time.current, updated_at: Time.current
      } ])
    end
  end

  test "policy composite foreign key rejects a cross-workspace calendar" do
    assert_raises(ActiveRecord::InvalidForeignKey) do
      SlaPolicy.insert_all!([ {
        workspace_id: @beta.id, service_calendar_id: @calendar.id,
        name: "Wrong tenant", priority: "low", first_response_minutes: 60,
        resolution_minutes: 240, warning_percent: 80, active: true,
        created_at: Time.current, updated_at: Time.current
      } ])
    end
  end

  test "case SLA composite foreign key rejects a cross-workspace policy" do
    assert_raises(ActiveRecord::InvalidForeignKey) do
      CaseSla.insert_all!([ {
        workspace_id: @beta.id, support_case_id: @beta_case.id, sla_policy_id: @policy.id,
        started_at: Time.current, first_response_warning_at: 1.hour.from_now,
        first_response_due_at: 2.hours.from_now, resolution_warning_at: 3.hours.from_now,
        resolution_due_at: 4.hours.from_now, first_response_status: "pending",
        resolution_status: "pending", paused_business_minutes: 0,
        created_at: Time.current, updated_at: Time.current
      } ])
    end
  end

  test "escalation composite foreign key rejects a cross-workspace case SLA" do
    assert_raises(ActiveRecord::InvalidForeignKey) do
      SlaEscalationTask.insert_all!([ {
        workspace_id: @beta.id, case_sla_id: @case_sla.id,
        objective: "resolution", kind: "warning", status: "open",
        occurred_at: Time.current, created_at: Time.current, updated_at: Time.current
      } ])
    end
  end

  test "an inactive policy does not block a new active policy for the priority" do
    @policy.update!(active: false)

    replacement = SlaPolicy.new(
      workspace: @acme,
      service_calendar: @calendar,
      name: "Replacement",
      priority: :normal,
      first_response_minutes: 30,
      resolution_minutes: 120,
      warning_percent: 75
    )

    assert_predicate replacement, :valid?
  end
end
