class MemoryVerificationJob < ApplicationJob
  queue_as :background

  def self.enqueue_after_commit(workspace)
    perform_later(workspace.id)
  rescue ActiveJob::EnqueueError
    Rails.logger.error("Memory verification job enqueue failed for workspace #{workspace.id}")
  end

  def perform(workspace_id, wait_count = 0)
    workspace = Workspace.find(workspace_id)
    return if workspace.deletion_requested?

    outcome = MemoryVerificationCheck.continue!(workspace:)
    return unless outcome&.result == "pending" && wait_count < 5

    self.class.set(wait: 30.seconds).perform_later(workspace_id, wait_count + 1)
  end
end
