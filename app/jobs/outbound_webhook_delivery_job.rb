class OutboundWebhookDeliveryJob < ApplicationJob
  queue_as :background

  def self.enqueue_after_commit(delivery)
    ActiveRecord.after_all_transactions_commit { perform_later(delivery.id) }
  rescue ActiveJob::EnqueueError
    Rails.logger.error("Outbound webhook enqueue failed for delivery #{delivery.id}")
  end

  def perform(delivery_id)
    delivery = claim!(delivery_id)
    return unless delivery

    deliver_with_current_endpoint!(delivery)
  rescue OutboundWebhookTransport::Error => error
    fail!(delivery, error)
  end

  private
    def transport
      @transport ||= OutboundWebhookTransport.new
    end

    def claim!(delivery_id)
      OutboundWebhookDelivery.transaction do
        delivery = OutboundWebhookDelivery.lock.find(delivery_id)
        return if delivery.workspace.deletion_requested?
        return if delivery.delivered? || delivery.attempt_count >= OutboundWebhookDelivery::MAX_ATTEMPTS
        return unless delivery.outbound_webhook_endpoint.active?
        return if delivery.sending? && delivery.last_attempted_at > 15.minutes.ago

        delivery.update!(status: :failed, failure_code: "interrupted") if delivery.sending?

        delivery.update!(status: :sending, attempt_count: delivery.attempt_count + 1, last_attempted_at: Time.current)
        delivery
      end
    end

    def deliver_with_current_endpoint!(delivery)
      Workspace.transaction do
        workspace = Workspace.lock.find_by(id: delivery.workspace_id)
        return unless workspace

        if workspace.deletion_requested?
          delivery.with_lock { delivery.update!(status: :failed, failure_code: "workspace_deleting") }
          return
        end

        endpoint = workspace.outbound_webhook_endpoints.lock.find(delivery.outbound_webhook_endpoint_id)
        unless endpoint.active?
          delivery.with_lock { delivery.update!(status: :failed, failure_code: "endpoint_inactive") }
          return
        end

        transport.deliver(delivery:)
        delivery.with_lock { delivery.update!(status: :delivered, delivered_at: Time.current, failure_code: nil) }
      end
    end

    def fail!(delivery, error)
      return unless delivery

      delivery.with_lock { delivery.update!(status: :failed, failure_code: error.retryable ? "delivery_failed" : "endpoint_rejected") }
      self.class.set(wait: 30.seconds).perform_later(delivery.id) if error.retryable &&
        delivery.attempt_count < OutboundWebhookDelivery::MAX_ATTEMPTS
    end
end
