# Runs the deterministic Account-health pass for one Workspace on the deployment
# schedule in config/recurring.yml. The recurring entry only enqueues one job per
# active Workspace, so the scheduler process never performs the calculation itself.
class AccountHealthScheduledRecalculationJob < ApplicationJob
  queue_as :background

  def self.enqueue_due
    Workspace.active.order(:id).find_each { |workspace| perform_later(workspace.id) }
  end

  def perform(workspace_id)
    workspace = Workspace.find_by(id: workspace_id)
    return if workspace.nil? || workspace.deletion_requested?

    AccountHealth.recalculate_due!(workspace:)
  end
end
