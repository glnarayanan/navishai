class OutboundWebhookEndpointsController < ApplicationController
  include WorkspaceAuthorization

  before_action :require_workspace
  before_action -> { require_role(:owner, :admin) }

  def index
    load_index
  end

  def create
    OutboundWebhookEndpoint.transaction do
      endpoint = Current.workspace.outbound_webhook_endpoints.create!(endpoint_params)
      audit_event("webhook.endpoint_configured", subject: endpoint, metadata: { active: endpoint.active.to_s })
    end
    redirect_to workspace_outbound_webhook_endpoints_path(Current.workspace), notice: "Webhook endpoint added."
  rescue ActiveRecord::RecordInvalid => error
    load_index
    @new_endpoint = error.record
    render :index, status: :unprocessable_content
  end

  def update
    resumed = false
    OutboundWebhookEndpoint.transaction do
      endpoint = Current.workspace.outbound_webhook_endpoints.lock.find(params[:id])
      was_active = endpoint.active?
      endpoint.update!(endpoint_params)
      resumed = !was_active && endpoint.active?
      audit_event("webhook.endpoint_configured", subject: endpoint, metadata: { active: endpoint.active.to_s })
    end
    if resumed
      Current.workspace.outbound_webhook_deliveries.where(outbound_webhook_endpoint_id: params[:id])
        .where(status: %w[pending failed]).where("attempt_count < ?", OutboundWebhookDelivery::MAX_ATTEMPTS)
        .find_each { |delivery| OutboundWebhookDeliveryJob.enqueue_after_commit(delivery) }
    end
    redirect_to workspace_outbound_webhook_endpoints_path(Current.workspace), notice: "Webhook endpoint saved."
  rescue ActiveRecord::RecordInvalid => error
    load_index
    @editing_endpoint = error.record
    render :index, status: :unprocessable_content
  end

  private
    def load_index
      @endpoints = Current.workspace.outbound_webhook_endpoints.order(:name)
      @new_endpoint ||= Current.workspace.outbound_webhook_endpoints.new(categories: Notification::CATEGORIES)
      @delivery_counts = Current.workspace.outbound_webhook_deliveries.group(:outbound_webhook_endpoint_id, :status).count
    end

    def endpoint_params
      params.require(:outbound_webhook_endpoint).permit(:name, :url, :credential_key, :active,
        categories: []).to_h
    end
end
