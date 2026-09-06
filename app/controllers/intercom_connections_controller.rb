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

  def help_center
    connection = Current.require_workspace!.intercom_connections.find(params[:id])
    connection.update!(help_center_sync_enabled: params.expect(intercom_connection: [ :help_center_sync_enabled ]).fetch(:help_center_sync_enabled))
    audit_event("intercom.help_center_configured", subject: connection)
    redirect_to workspace_intercom_connections_path(Current.workspace), notice: "Help Center sync settings saved."
  end

  def sync_help_center
    connection = Current.require_workspace!.intercom_connections.active.find(params[:id])
    return head :unprocessable_content unless connection.help_center_sync_enabled?
    IntercomHelpCenterSyncJob.perform_later(connection.id)
    audit_event("intercom.help_center_requested", subject: connection)
    redirect_to workspace_intercom_connections_path(Current.workspace), notice: "Help Center sync queued."
  end

  def backfill_preview
    connection = Current.require_workspace!.intercom_connections.active.find(params[:id])
    manifest = IntercomHistoricalBackfill.preview!(
      connection:, membership: Current.require_membership!
    )
    redirect_to workspace_intercom_connections_path(Current.workspace, anchor: "historical-backfill-#{connection.id}"),
      notice: "Dry run ready: #{manifest.counts.fetch('conversations')} conversations. Review and confirm the exact manifest."
  rescue IntercomClient::Error, IntercomHistoricalBackfill::BoundaryChanged, ArgumentError => error
    redirect_to workspace_intercom_connections_path(Current.workspace), alert: error.message
  end

  def backfill_confirm
    connection = Current.require_workspace!.intercom_connections.active.find(params[:id])
    manifest = connection.intercom_backfill_manifests.find(params[:manifest_id])
    run = IntercomHistoricalBackfill.confirm!(
      connection:, manifest:, membership: Current.require_membership!, expected_digest: params.require(:source_digest)
    )
    redirect_to workspace_intercom_connections_path(Current.workspace, anchor: "historical-backfill-#{connection.id}"),
      notice: run.blocked? ? "Historical backfill needs review. Correct the source and start a new dry run." :
        "Historical backfill confirmed. Bounded background batches have started."
  rescue IntercomHistoricalBackfill::StaleManifest => error
    redirect_to workspace_intercom_connections_path(Current.workspace), alert: error.message
  end

  def backfill_resume
    connection = Current.require_workspace!.intercom_connections.active.find(params[:id])
    run = connection.intercom_backfill_runs.find(params[:run_id])
    IntercomHistoricalBackfill.resume!(run:, membership: Current.require_membership!)
    redirect_to workspace_intercom_connections_path(Current.workspace, anchor: "historical-backfill-#{connection.id}"),
      notice: "Historical backfill queued from its last definite record."
  rescue ArgumentError => error
    redirect_to workspace_intercom_connections_path(Current.workspace), alert: error.message
  end

  def backfill_resolve_identity
    connection = Current.require_workspace!.intercom_connections.find(params[:id])
    exception = Current.require_workspace!.intercom_backfill_exceptions
      .joins(:intercom_backfill_manifest)
      .where(intercom_backfill_manifests: { intercom_connection_id: connection.id })
      .find(params[:exception_id])
    identity = exception.source_identity || raise(ActiveRecord::RecordNotFound)
    target = identity.account? ? Current.workspace.accounts.find(params[:target_id]) : Current.workspace.contacts.find(params[:target_id])
    IdentityMatchReview.resolve!(
      workspace: Current.workspace, source_identity: identity, target:, membership: Current.require_membership!
    )
    identity.intercom_backfill_exceptions.open.update_all(status: "resolved", resolved_at: Time.current, updated_at: Time.current)
    redirect_to workspace_intercom_connections_path(Current.workspace, anchor: "historical-backfill-#{connection.id}"),
      notice: "Identity match saved. Resume the backfill from the same record."
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
      @backfill_manifests = workspace.intercom_backfill_manifests
        .includes(:intercom_backfill_exceptions).order(created_at: :desc, id: :desc)
        .group_by(&:intercom_connection_id)
      @backfill_runs = workspace.intercom_backfill_runs
        .includes(:intercom_backfill_report,
          intercom_backfill_exceptions: { source_identity: { identity_match_candidates: [ :account, :contact ] } })
        .order(created_at: :desc, id: :desc).group_by(&:intercom_connection_id)
      @connection = connection
    end
end
