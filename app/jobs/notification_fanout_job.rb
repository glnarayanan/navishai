class NotificationFanoutJob < ApplicationJob
  queue_as :background

  def self.enqueue_after_commit(audit_event)
    ActiveRecord.after_all_transactions_commit do
      perform_later(audit_event.id)
    rescue ActiveJob::EnqueueError
      Rails.logger.error("Notification fanout enqueue failed for audit event #{audit_event.id}")
    end
  end

  def perform(audit_event_id)
    event = AuditEvent.find(audit_event_id)
    return if event.workspace&.deletion_requested?

    NotificationFanout.call(event)
  end
end
