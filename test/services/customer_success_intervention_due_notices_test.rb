require "test_helper"

class CustomerSuccessInterventionDueNoticesTest < ActiveJob::TestCase
  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
    @account = accounts(:acme)
    @as_of = Date.current
    CrewConfiguration.install_defaults!(workspace: @workspace)
    @assessment = AccountHealth.recalculate!(
      workspace: @workspace, account: @account, trigger_kind: "human_request", membership: @owner
    )
  end

  test "notifies the current assignee once per due-state and target date" do
    member = create_follow_up_membership("due-member", :member)
    other = create_follow_up_membership("due-other", :member)
    plan, = create_reviewed_intervention_plan(
      workspace: @workspace, account: @account, membership: @owner, assessment: @assessment
    )
    intervention = CustomerSuccessInterventionWorkflow.propose!(
      workspace: @workspace, membership: @owner, account: @account, assessment: @assessment,
      artifact: plan, accountable_membership: member,
      expected_observable_change: "Increase deterministic Account health evidence.",
      target_on: @as_of, reason: "Due today for the accountable human.", at: 2.days.ago
    )

    assert_equal 1, CustomerSuccessInterventionDueNotices.deliver!(workspace: @workspace, as_of: @as_of)
    assert_equal 0, CustomerSuccessInterventionDueNotices.deliver!(workspace: @workspace, as_of: @as_of)
    notice = intervention.due_notices.sole
    assert notice.due_state_due?
    event = notice.source_audit_event
    assert_equal 1, NotificationFanout.call(event)
    assert_no_difference "Notification.count" do
      NotificationFanout.call(event)
    end
    assert_equal 1, member.notifications.count
    assert member.notifications.sole.category_due?
    assert_empty other.notifications

    CustomerSuccessInterventionWorkflow.reassign!(
      workspace: @workspace, membership: @owner, intervention:, accountable_membership: other,
      reason: "The original owner left the rotation."
    )
    assert_equal 1, CustomerSuccessInterventionDueNotices.deliver!(workspace: @workspace, as_of: @as_of)
    other_notice = intervention.due_notices.find_by!(recipient_membership: other)
    assert_equal 1, NotificationFanout.call(other_notice.source_audit_event)
    assert_equal 1, other.notifications.count
    assert_equal 1, member.notifications.count
    assert_equal 0, NotificationFanout.call(event)

    overdue_plan, = create_reviewed_intervention_plan(
      workspace: @workspace, account: @account, membership: @owner, assessment: @assessment
    )
    overdue = CustomerSuccessInterventionWorkflow.propose!(
      workspace: @workspace, membership: @owner, account: @account, assessment: @assessment,
      artifact: overdue_plan, accountable_membership: member,
      expected_observable_change: "Review the overdue observed change.",
      target_on: @as_of - 1.day, reason: "This bounded follow-up is overdue.", at: 3.days.ago
    )
    CustomerSuccessInterventionWorkflow.approve!(
      workspace: @workspace, membership: @owner, intervention: overdue
    )
    CustomerSuccessInterventionWorkflow.complete!(
      workspace: @workspace, membership: member, intervention: overdue
    )
    assert_equal 0, CustomerSuccessInterventionDueNotices.deliver!(workspace: @workspace, as_of: @as_of)
    assert_empty overdue.due_notices
  end

  test "does not notify a former assignee when fanout runs after reassignment" do
    member = create_follow_up_membership("due-former", :member)
    other = create_follow_up_membership("due-current", :member)
    plan, = create_reviewed_intervention_plan(
      workspace: @workspace, account: @account, membership: @owner, assessment: @assessment
    )
    intervention = CustomerSuccessInterventionWorkflow.propose!(
      workspace: @workspace, membership: @owner, account: @account, assessment: @assessment,
      artifact: plan, accountable_membership: member,
      expected_observable_change: "Increase deterministic Account health evidence.",
      target_on: @as_of, reason: "Due today before ownership moved.", at: 2.days.ago
    )

    assert_equal 1, CustomerSuccessInterventionDueNotices.deliver!(workspace: @workspace, as_of: @as_of)
    notice = intervention.due_notices.sole
    CustomerSuccessInterventionWorkflow.reassign!(
      workspace: @workspace, membership: @owner, intervention:, accountable_membership: other,
      reason: "Ownership moved before the due notice was delivered."
    )

    assert_equal 0, NotificationFanout.call(notice.source_audit_event)
    assert_empty member.notifications
    assert_empty other.notifications
  end

  test "abandoned and future follow-ups stay off the due queue" do
    member = create_follow_up_membership("due-abandoned", :member)
    abandoned_plan, = create_reviewed_intervention_plan(
      workspace: @workspace, account: @account, membership: @owner, assessment: @assessment
    )
    abandoned = CustomerSuccessInterventionWorkflow.propose!(
      workspace: @workspace, membership: @owner, account: @account, assessment: @assessment,
      artifact: abandoned_plan, accountable_membership: member,
      expected_observable_change: "Abandon this overdue follow-up.",
      target_on: @as_of - 1.day, reason: "Overdue work the manager will abandon.", at: 3.days.ago
    )
    future_plan, = create_reviewed_intervention_plan(
      workspace: @workspace, account: @account, membership: @owner, assessment: @assessment
    )
    CustomerSuccessInterventionWorkflow.propose!(
      workspace: @workspace, membership: @owner, account: @account, assessment: @assessment,
      artifact: future_plan, accountable_membership: member,
      expected_observable_change: "Keep this future follow-up off the due queue.",
      target_on: @as_of + 5.days, reason: "Not due yet.", at: Time.current
    )
    CustomerSuccessInterventionWorkflow.abandon!(
      workspace: @workspace, membership: @owner, intervention: abandoned,
      reason: "The Account chose a different path."
    )

    assert_equal 0, CustomerSuccessInterventionDueNotices.deliver!(workspace: @workspace, as_of: @as_of)
    assert_empty abandoned.due_notices
  end

  test "the recurring job skips deleting Workspaces and does not complete interventions" do
    deleting = workspaces(:beta_support)
    deleting.update!(deletion_requested_at: Time.current)

    assert_enqueued_jobs Workspace.active.count, only: CustomerSuccessInterventionDueNoticeJob do
      CustomerSuccessInterventionDueNoticeJob.enqueue_due
    end
    assert_no_difference "CustomerSuccessInterventionDueNotice.count" do
      CustomerSuccessInterventionDueNoticeJob.perform_now(deleting.id)
    end
    assert_no_difference "@workspace.customer_success_interventions.where(status: :completed).count" do
      CustomerSuccessInterventionDueNoticeJob.perform_now(@workspace.id)
    end
  end

  private
    def create_follow_up_membership(prefix, role)
      user = User.create!(
        email_address: "#{prefix}-#{SecureRandom.hex(3)}@example.com",
        password: "password12345", verified_at: Time.current
      )
      @workspace.memberships.create!(user:, role:)
    end
end
