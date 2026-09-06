require "test_helper"

class IntercomHelpCenterSyncJobTest < ActiveJob::TestCase
  test "schedules enabled connections only and missing connection is harmless" do
    workspace = workspaces(:acme_support)
    enabled = workspace.intercom_connections.create!(name: "Docs", remote_workspace_id: "docs", credential_key: "docs", help_center_sync_enabled: true)
    workspace.intercom_connections.create!(name: "Manual", remote_workspace_id: "manual", credential_key: "manual")
    assert_enqueued_with(job: IntercomHelpCenterSyncJob, args: [ enabled.id ]) { IntercomHelpCenterSyncJob.enqueue_due }
    assert_nothing_raised { IntercomHelpCenterSyncJob.perform_now(-1) }
  end
end
