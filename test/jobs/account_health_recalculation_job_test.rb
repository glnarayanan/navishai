require "test_helper"

class AccountHealthRecalculationJobTest < ActiveJob::TestCase
  setup do
    @account = accounts(:acme)
  end

  test "recalculates from a retained account after relevant records commit" do
    assert_difference "@account.health_assessments.count", 1 do
      AccountHealthRecalculationJob.perform_now(@account.id)
    end
    assert_equal "input_change", @account.current_health_assessment.trigger_kind
    assert AuditEvent.exists?(action: "account.health_recalculated", actor_kind: "system")
  end

  test "conversation, note, case, and SLA changes enqueue recalculation only for linked accounts" do
    support_case = create_support_case(contact: contacts(:alice))
    message = nil
    assert_enqueued_with(job: AccountHealthRecalculationJob, args: [ @account.id ]) do
      message = add_inbound_message(support_case)
    end
    assert message.persisted?

    assert_enqueued_with(job: AccountHealthRecalculationJob, args: [ @account.id ]) do
      support_case.case_notes.create!(workspace: @account.workspace, author: users(:owner), body: "Renewal context")
    end
    assert_enqueued_with(job: AccountHealthRecalculationJob, args: [ @account.id ]) do
      support_case.update!(priority: :high)
    end
    calendar = ServiceCalendar.create!(workspace: @account.workspace, name: "Health test hours", time_zone: "UTC",
      weekly_hours: %w[monday tuesday wednesday thursday friday].index_with { [ [ "09:00", "17:00" ] ] })
    SlaPolicy.create!(workspace: @account.workspace, service_calendar: calendar, name: "Health test SLA",
      priority: :high, first_response_minutes: 60, resolution_minutes: 240, warning_percent: 75)
    SlaEngine.start!(workspace: @account.workspace, support_case: support_case)
    assert_enqueued_with(job: AccountHealthRecalculationJob, args: [ @account.id ]) do
      support_case.case_sla.update!(first_response_status: :breached)
    end
  end
end
