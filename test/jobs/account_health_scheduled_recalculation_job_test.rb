require "test_helper"

class AccountHealthScheduledRecalculationJobTest < ActiveJob::TestCase
  setup do
    @workspace = workspaces(:acme_support)
    @account = accounts(:acme)
  end

  test "recalculates every Account in the Workspace with the schedule trigger" do
    assert_difference "@account.health_assessments.count", 1 do
      AccountHealthScheduledRecalculationJob.perform_now(@workspace.id)
    end
    assert_equal "schedule", @account.current_health_assessment.trigger_kind
    assert AuditEvent.exists?(action: "account.health_recalculated", actor_kind: "system")
  end

  test "an Account inside its renewal window records the renewal trigger" do
    AccountDataImport.import_api!(
      workspace: @workspace, membership: memberships(:owner_support),
      rows: [ { "source_id" => "sched-1", "account_name" => @account.name, "renewal_on" => 30.days.from_now.to_date.iso8601 } ]
    )
    AccountHealthScheduledRecalculationJob.perform_now(@workspace.id)
    assert_equal "renewal_window", @account.reload.current_health_assessment.trigger_kind
  end

  test "the recurring entry enqueues one job per active Workspace and skips deletion" do
    deleting = workspaces(:beta_support)
    deleting.update!(deletion_requested_at: Time.current)

    assert_enqueued_jobs Workspace.active.count, only: AccountHealthScheduledRecalculationJob do
      AccountHealthScheduledRecalculationJob.enqueue_due
    end
    assert_no_enqueued_jobs(only: AccountHealthScheduledRecalculationJob) do
      # Enqueued earlier but the Workspace is now deleting: the job must do nothing.
      assert_no_difference "AccountHealthAssessment.count" do
        AccountHealthScheduledRecalculationJob.perform_now(deleting.id)
      end
    end
  end

  test "production recurring schedule enqueues the health pass before retention expiry" do
    schedule = YAML.load_file(Rails.root.join("config/recurring.yml")).fetch("production")
    entry = schedule.fetch("recalculate_account_health")
    assert_equal "AccountHealthScheduledRecalculationJob.enqueue_due", entry.fetch("command")
    assert_equal "every day at 1:30am", entry.fetch("schedule")
    assert_respond_to AccountHealthScheduledRecalculationJob, :enqueue_due
  end
end
