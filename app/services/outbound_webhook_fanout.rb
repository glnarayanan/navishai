class OutboundWebhookFanout
  def self.call(notification)
    notification.workspace.outbound_webhook_endpoints.active.find_each do |endpoint|
      next unless endpoint.categories.include?(notification.category)

      delivery = endpoint.outbound_webhook_deliveries.find_or_create_by!(notification:) do |record|
        record.workspace = notification.workspace
      end
      OutboundWebhookDeliveryJob.enqueue_after_commit(delivery) if delivery.pending?
    end
  end
end
