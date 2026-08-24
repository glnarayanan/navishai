class WorkspaceContentExpiryJob < ApplicationJob
  queue_as :background

  def self.enqueue_after_commit(run)
    ActiveRecord.after_all_transactions_commit { perform_later(run.id) }
  rescue ActiveJob::EnqueueError
    Rails.logger.error("Workspace content expiry enqueue failed for run #{run.id}")
  end

  def perform(run_id)
    run = WorkspaceContentExpiryRun.find(run_id)
    return if run.workspace.deletion_requested?

    WorkspaceContentExpiry.perform!(run:)
  end
end
