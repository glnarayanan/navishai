require "test_helper"

class SlaEngineTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:acme_support)
    @calendar = ServiceCalendar.create!(
      workspace: @workspace,
      name: "Support hours",
      time_zone: "UTC",
      weekly_hours: %w[monday tuesday wednesday thursday friday].index_with { [ [ "09:00", "17:00" ] ] }
    )
    @policy = SlaPolicy.create!(
      workspace: @workspace,
      service_calendar: @calendar,
      name: "Normal priority",
      priority: :normal,
      first_response_minutes: 120,
      resolution_minutes: 480,
      warning_percent: 75
    )
    @monday = Time.zone.parse("2026-08-24 09:00:00 UTC")
  end

  test "case creation snapshots deterministic warning and due times" do
    support_case = create_case(at: @monday)
    case_sla = support_case.case_sla

    assert_equal @policy, case_sla.sla_policy
    assert_equal @monday + 90.minutes, case_sla.first_response_warning_at
    assert_equal @monday + 120.minutes, case_sla.first_response_due_at
    assert_equal @monday + 360.minutes, case_sla.resolution_warning_at
    assert_equal @monday + 480.minutes, case_sla.resolution_due_at
    assert AuditEvent.where(action: "case.sla_started", subject_id: case_sla.id).exists?
  end

  test "a one-minute target warns at the start and remains before its deadline" do
    @policy.update!(first_response_minutes: 1)

    case_sla = create_case(at: @monday).case_sla

    assert_equal @monday, case_sla.first_response_warning_at
    assert_equal @monday + 1.minute, case_sla.first_response_due_at
  end

  test "waiting on customer pauses clocks and resume shifts them by paused business time" do
    support_case = create_case(at: @monday)
    case_sla = support_case.case_sla

    SlaEngine.status_changed!(workspace: @workspace, support_case: support_case, from: "investigating", to: "waiting_customer", at: @monday + 1.hour)
    SlaEngine.status_changed!(workspace: @workspace, support_case: support_case, from: "waiting_customer", to: "investigating", at: @monday + 25.hours)

    case_sla.reload
    assert_nil case_sla.paused_at
    assert_equal 480, case_sla.paused_business_minutes
    assert_equal Time.zone.parse("2026-08-25 17:00:00 UTC"), case_sla.resolution_due_at
  end

  test "warnings and breaches create idempotent escalation tasks" do
    support_case = create_case(at: @monday)
    case_sla = support_case.case_sla

    assert_difference [ "SlaEscalationTask.count", "AuditEvent.count" ], 1 do
      SlaEngine.evaluate!(workspace: @workspace, at: case_sla.first_response_warning_at)
    end
    assert_difference [ "SlaEscalationTask.count", "AuditEvent.count" ], 1 do
      SlaEngine.evaluate!(workspace: @workspace, at: case_sla.first_response_due_at)
    end
    assert_no_difference [ "SlaEscalationTask.count", "AuditEvent.count" ] do
      SlaEngine.evaluate!(workspace: @workspace, at: case_sla.first_response_due_at + 1.minute)
    end

    assert_equal %w[breach warning], case_sla.escalation_tasks.where(objective: :first_response).order(:kind).pluck(:kind)
    assert case_sla.reload.first_response_breached?
    assert case_sla.escalation_tasks.find_by(objective: :first_response, kind: :warning).completed?
    assert case_sla.escalation_tasks.find_by(objective: :first_response, kind: :breach).open?
  end

  test "an outbound record completes first response without granting send authority" do
    support_case = create_case(at: @monday)
    message = @workspace.conversation_messages.create!(
      conversation: support_case.conversation,
      direction: :outbound,
      author_kind: :user,
      author_user: users(:owner),
      body: "Recorded response",
      occurred_at: @monday + 30.minutes
    )

    SlaEngine.record_first_response!(workspace: @workspace, support_case: support_case, message: message)

    assert support_case.case_sla.reload.first_response_met?
    assert_equal @monday + 30.minutes, support_case.case_sla.first_responded_at
  end

  test "an earlier historical outbound message corrects the first response" do
    support_case = create_case(at: @monday)
    late_message = outbound_message(support_case, at: @monday + 3.hours)
    early_message = outbound_message(support_case, at: @monday + 30.minutes)

    SlaEngine.record_first_response!(workspace: @workspace, support_case: support_case, message: late_message)
    assert support_case.case_sla.reload.first_response_breached?

    SlaEngine.record_first_response!(workspace: @workspace, support_case: support_case, message: early_message)

    assert support_case.case_sla.reload.first_response_met?
    assert_equal @monday + 30.minutes, support_case.case_sla.first_responded_at
    assert support_case.case_sla.escalation_tasks.where(objective: :first_response, status: :open).none?
  end

  test "case creation without an active policy remains atomic and creates no SLA" do
    @policy.update!(active: false)

    assert_difference "SupportCase.count", 1 do
      assert_no_difference "CaseSla.count" do
        assert_nil create_case(at: @monday).case_sla
      end
    end
  end

  test "SLA audit failure rolls back case and conversation creation" do
    original_record = AuditEvent.method(:record!)
    AuditEvent.singleton_class.define_method(:record!) { |**| raise ActiveRecord::RecordInvalid, AuditEvent.new }

    assert_no_difference [ "Conversation.count", "SupportCase.count", "CaseSla.count" ] do
      assert_raises(ActiveRecord::RecordInvalid) { create_case(at: @monday) }
    end
  ensure
    AuditEvent.singleton_class.define_method(:record!, original_record) if original_record
  end

  test "inbound and foreign messages cannot complete first response" do
    support_case = create_case(at: @monday)
    inbound = add_inbound_message(support_case, occurred_at: @monday + 30.minutes)
    foreign_case = create_support_case(
      workspace: workspaces(:beta_support), contact: contacts(:bob), membership: memberships(:outsider_beta)
    )
    foreign_message = workspaces(:beta_support).conversation_messages.create!(
      conversation: foreign_case.conversation,
      direction: :outbound,
      author_kind: :user,
      author_user: users(:outsider),
      body: "Other workspace response",
      occurred_at: @monday + 30.minutes
    )

    assert_raises(ArgumentError) do
      SlaEngine.record_first_response!(workspace: @workspace, support_case: support_case, message: inbound)
    end
    assert_raises(ActiveRecord::RecordNotFound) do
      SlaEngine.record_first_response!(workspace: @workspace, support_case: support_case, message: foreign_message)
    end
    assert support_case.case_sla.reload.first_response_pending?
  end

  test "resolution completion follows the case workflow transaction" do
    support_case = create_case(at: @monday)
    support_case.update!(status: :investigating, status_changed_at: @monday)

    CaseWorkflow.transition!(
      workspace: @workspace, support_case: support_case,
      membership: memberships(:owner_support), to: :resolved,
      reason: "Solved", occurred_at: @monday + 2.hours
    )

    assert support_case.case_sla.reload.resolution_met?
    assert_equal @monday + 2.hours, support_case.case_sla.resolved_at
  end

  test "a fresh inbound message reopens the resolution clock after terminal time" do
    support_case = create_case(at: @monday)
    support_case.update!(status: :investigating, status_changed_at: @monday)
    CaseWorkflow.transition!(
      workspace: @workspace, support_case: support_case,
      membership: memberships(:owner_support), to: :resolved,
      reason: "Solved", occurred_at: @monday + 1.hour
    )

    travel_to @monday + 25.hours do
      ConversationThread.append_inbound!(
        workspace: @workspace,
        conversation: support_case.conversation,
        author: contacts(:alice),
        body: "The issue returned",
        occurred_at: @monday + 25.hours,
        source: :integration
      )
    end

    case_sla = support_case.case_sla.reload
    assert case_sla.resolution_pending?
    assert_nil case_sla.resolved_at
    assert_equal Time.zone.parse("2026-08-25 17:00:00 UTC"), case_sla.resolution_due_at
  end

  test "audit failure rolls back breach state and task" do
    support_case = create_case(at: @monday)
    case_sla = support_case.case_sla
    original_record = AuditEvent.method(:record!)
    AuditEvent.singleton_class.define_method(:record!) { |**| raise ActiveRecord::RecordInvalid, AuditEvent.new }

    assert_no_difference "SlaEscalationTask.count" do
      assert_raises(ActiveRecord::RecordInvalid) do
        SlaEngine.evaluate!(workspace: @workspace, at: case_sla.first_response_due_at)
      end
    end
    assert case_sla.reload.first_response_pending?
  ensure
    AuditEvent.singleton_class.define_method(:record!, original_record) if original_record
  end

  private
    def create_case(at:)
      ConversationThread.start!(
        workspace: @workspace,
        contact: contacts(:alice),
        membership: memberships(:owner_support),
        subject: "SLA case",
        occurred_at: at
      ).support_case
    end

    def outbound_message(support_case, at:)
      @workspace.conversation_messages.create!(
        conversation: support_case.conversation,
        direction: :outbound,
        author_kind: :user,
        author_user: users(:owner),
        body: "Recorded response",
        occurred_at: at
      )
    end
end
