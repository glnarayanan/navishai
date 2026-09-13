class CustomerSuccessInterventionDueNoticeJob < ApplicationJob
  queue_as :background

  def self.enqueue_due
    Workspace.active.order(:id).find_each { |workspace| perform_later(workspace.id) }
  end

  def perform(workspace_id)
    workspace = Workspace.find_by(id: workspace_id)
    return if workspace.nil? || workspace.deletion_requested?

    CustomerSuccessInterventionDueNotices.deliver!(workspace:)
  end
end
