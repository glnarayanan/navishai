class WorkspaceDeletionJob < ApplicationJob
  queue_as :background

  def self.enqueue_after_commit(request)
    ActiveRecord.after_all_transactions_commit do
      raise ActiveJob::EnqueueError, "workspace deletion was not enqueued" unless perform_later(request.id)
    rescue ActiveJob::EnqueueError
      record_enqueue_failure!(request)
    end
  end

  def self.record_enqueue_failure!(request)
    request.with_lock do
      request.update!(status: :failed, failure_code: "enqueue_error", completed_at: Time.current)
      AuditEvent.record!(
        action: "workspace.deletion_failed", source: :job, workspace: request.workspace,
        actor_kind: :system, subject: request, metadata: { failure_code: "enqueue_error" }
      )
    end
    Rails.logger.error("Workspace deletion enqueue failed for request #{request.id}")
  end
  private_class_method :record_enqueue_failure!

  def perform(request_id)
    WorkspaceDeletion.perform!(request: WorkspaceDeletionRequest.find(request_id))
  end
end
