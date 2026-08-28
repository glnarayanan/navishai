class IntercomBackfillJob < ApplicationJob
  queue_as :background

  def self.enqueue_after_commit(run)
    ActiveRecord.after_all_transactions_commit do
      raise ActiveJob::EnqueueError, "Intercom backfill was not enqueued" unless perform_later(run.id)
    rescue ActiveJob::EnqueueError
      record_enqueue_failure!(run)
    end
  end

  def self.record_enqueue_failure!(run)
    run.with_lock do
      return unless run.pending?

      run.update!(status: :failed, failure_code: "enqueue_error", completed_at: Time.current)
      AuditEvent.record!(
        action: "intercom.backfill_enqueue_failed", source: :job, workspace: run.workspace,
        actor_kind: :system, subject: run, metadata: { cursor_position: run.cursor_position }
      )
    end
    Rails.logger.error("Intercom backfill enqueue failed for run #{run.id}")
  end
  private_class_method :record_enqueue_failure!

  def perform(run_id)
    run = IntercomBackfillRun.find(run_id)
    return if run.workspace.deletion_requested?

    IntercomHistoricalBackfill.perform!(run:)
    self.class.enqueue_after_commit(run.reload) if run.pending?
  end
end
