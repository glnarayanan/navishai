class WorkspaceConnectorsController < ApplicationController
  include WorkspaceAuthorization

  before_action :require_workspace, except: :oauth_return
  before_action :prevent_credential_caching
  before_action :load_connector, except: %i[index oauth_return]
  before_action :require_connector_admin, only: :update
  rescue_from IntegrationOauth::Unavailable, ActiveRecord::Encryption::Errors::Base, with: :connection_unavailable

  def oauth_return
    state = params[:state]
    raise ActiveRecord::RecordNotFound unless state.is_a?(String) && state.bytesize.between?(32, 128)

    attempt = IntegrationOauthAttempt.includes(:workspace_connector).find_by!(
      state_digest: Digest::SHA256.hexdigest(state), session: Current.session, consumed_at: nil)
    raise ActiveRecord::RecordNotFound unless attempt.workspace_connector.provider == params[:provider] && attempt.expires_at.future?

    redirect_to callback_workspace_workspace_connector_path(attempt.workspace_id, params[:provider],
      state:, code: params[:code], error: params[:error])
  end

  def index
    @connectors = WorkspaceConnector.where(workspace: Current.workspace).index_by(&:provider)
    @connections = IntegrationUserConnection.where(workspace: Current.workspace, membership: Current.require_membership!)
      .includes(:workspace_connector).index_by { |connection| connection.workspace_connector.provider }
  end

  def update
    attributes = params.expect(workspace_connector: [ :enabled, :service_token, :remove_service_token ])
    remote_workspace_id = if @connector.provider == "intercom" && attributes[:service_token].present? && attributes[:remove_service_token] != "1"
      IntegrationOauth.new("intercom").intercom_identity(token: attributes[:service_token]).dig("app", "id_code")
    end
    @connector.with_lock do
      @connector.enabled = ActiveModel::Type::Boolean.new.cast(attributes[:enabled]) if attributes.key?(:enabled)
      @connector.service_token = attributes[:service_token] if attributes[:service_token].present?
      @connector.service_remote_workspace_id = remote_workspace_id if remote_workspace_id
      if attributes[:remove_service_token] == "1"
        @connector.service_token = nil
        @connector.service_remote_workspace_id = nil
      end
      @connector.save!
      @connector.integration_oauth_attempts.delete_all unless @connector.enabled?
      audit_event("connector.configured", subject: @connector)
    end
    redirect_to workspace_workspace_connectors_path(Current.workspace), notice: "Connector settings saved."
  rescue ActiveRecord::RecordInvalid
    redirect_to workspace_workspace_connectors_path(Current.workspace), alert: "Check the connector settings."
  end

  def connect
    raise IntegrationOauth::Unavailable unless @connector.enabled?

    oauth = IntegrationOauth.new(@connector.provider)
    raise IntegrationOauth::Unavailable unless oauth.configured?

    state = IntegrationOauthAttempt.issue!(connector: @connector,
      membership: Current.require_membership!, session: Current.session)
    redirect_to oauth.authorization_url(state:), allow_other_host: true
  end

  def callback
    membership = Current.require_membership!
    IntegrationOauthAttempt.consume!(state: params[:state], connector: @connector, membership:, session: Current.session)
    raise IntegrationOauth::Unavailable if params[:error].present?

    attributes = IntegrationOauth.new(@connector.provider).exchange(code: params[:code])
    @connector.with_lock do
      raise IntegrationOauth::Unavailable unless @connector.enabled? &&
        Membership.exists?(id: membership.id, workspace: Current.workspace, user: Current.user)

      connection = IntegrationUserConnection.find_or_initialize_by(workspace: Current.workspace,
        workspace_connector: @connector, membership:)
      connection.update!(attributes)
      audit_event("connector.connected", subject: connection)
    end
    redirect_to workspace_workspace_connectors_path(Current.workspace), notice: "Your account is connected."
  rescue ActiveRecord::RecordNotFound, ActiveRecord::RecordInvalid
    connection_unavailable
  end

  def content
    membership = Current.require_membership!
    connection = IntegrationUserConnection.find_by!(workspace: Current.workspace,
      workspace_connector: @connector, membership:)
    @items = IntegrationOauth.new(@connector.provider).personal_content(token: connection.access_token_for!(membership))
    connection.reload.access_token_for!(membership)
  end

  def disconnect
    connection = IntegrationUserConnection.find_by!(workspace: Current.workspace,
      workspace_connector: @connector, membership: Current.require_membership!)
    connection.transaction do
      audit_event("connector.disconnected", subject: connection)
      connection.destroy!
      @connector.integration_oauth_attempts.where(membership: Current.require_membership!).delete_all
    end
    redirect_to workspace_workspace_connectors_path(Current.workspace), notice: "Your account was disconnected."
  end

  private
    def load_connector
      provider = params[:provider]
      raise ActiveRecord::RecordNotFound unless WorkspaceConnector::PROVIDERS.include?(provider)

      @connector = WorkspaceConnector.find_or_initialize_by(workspace: Current.workspace, provider:)
    end

    def require_connector_admin
      head :forbidden unless Current.require_membership!.can_configure_integrations?
    end

    def prevent_credential_caching
      response.headers["Cache-Control"] = "no-store"
      response.headers["Pragma"] = "no-cache"
      response.headers["Referrer-Policy"] = "same-origin"
    end

    def connection_unavailable
      redirect_to workspace_workspace_connectors_path(Current.workspace),
        alert: "The connection could not be completed. Check connector setup and try connecting again."
    end
end
