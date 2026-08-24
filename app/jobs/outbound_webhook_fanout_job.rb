class OutboundWebhookFanoutJob < ApplicationJob
  queue_as :background

  def self.enqueue_after_commit(notification)
    ActiveRecord.after_all_transactions_commit { perform_later(notification.id) }
  rescue ActiveJob::EnqueueError
    Rails.logger.error("Outbound webhook fanout enqueue failed for notification #{notification.id}")
  end

  def perform(notification_id)
    notification = Notification.find(notification_id)
    return if notification.workspace.deletion_requested?

    OutboundWebhookFanout.call(notification)
  end
end
