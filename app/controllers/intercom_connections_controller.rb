class IntercomConnectionsController < ApplicationController
  include WorkspaceAuthorization

  before_action :require_workspace
  before_action :require_integration_admin

  def index
    load_index
  end

  def create
    connection = IntercomConnection.transaction do
      Current.require_workspace!.intercom_connections.create!(connection_params).tap do |created|
        audit_event("intercom.connection_created", subject: created)
      end
    end
    redirect_to workspace_intercom_connections_path(Current.workspace), notice: "Intercom connection added."
  rescue ActiveRecord::RecordInvalid => error
    load_index(connection: error.record)
    render :index, status: :unprocessable_content
  end

  def update
    connection = Current.require_workspace!.intercom_connections.find(params[:id])
    IntercomConnection.transaction do
      connection.lock!
      connection.update!(active: params.require(:intercom_connection).require(:active))
      audit_event("intercom.connection_updated", subject: connection, metadata: { active: connection.active?.to_s })
    end
    redirect_to workspace_intercom_connections_path(Current.workspace), notice: "Intercom connection updated."
  end

  def reconcile
    connection = Current.require_workspace!.intercom_connections.active.find(params[:id])
    outbound = IntercomOutboundSync.retry!(connection: connection)
    retries = IntercomSync.retry!(connection: connection, membership: Current.require_membership!)
    count = IntercomSync.reconcile!(connection: connection)
    redirect_to workspace_intercom_connections_path(Current.workspace),
      notice: "Retried #{outbound.size} outbound changes and #{retries.size} events; reconciled #{count} conversations."
  rescue IntercomClient::Error => error
    redirect_to workspace_intercom_connections_path(Current.workspace), alert: error.message
  rescue IntercomSync::IdentityAmbiguous
    redirect_to workspace_intercom_connections_path(Current.workspace), alert: "Intercom identity needs review."
  end

  private
    def require_integration_admin
      head :forbidden unless Current.require_membership!.can_configure_integrations?
    end

    def connection_params
      params.expect(intercom_connection: [ :name, :remote_workspace_id, :credential_key ])
    end

    def load_index(connection: IntercomConnection.new)
      workspace = Current.require_workspace!
      @connections = workspace.intercom_connections.order(:name, :id)
      retryable = workspace.intercom_webhook_deliveries.retryable
      terminal = workspace.intercom_webhook_deliveries.where(status: %w[received failed]).where.not(id: retryable.select(:id))
      @retry_counts = retryable.group(:intercom_connection_id).count
      @terminal_failure_counts = terminal.group(:intercom_connection_id, :failure_code).count
      @operation_review_counts = workspace.intercom_sync_operations
        .where(status: %w[sending failed unknown])
        .group(:intercom_connection_id, :failure_code).count
      @connection = connection
    end
end
