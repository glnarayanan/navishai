class NotionKnowledgeConnectionsController < ApplicationController
  include WorkspaceAuthorization
  before_action :require_workspace
  before_action :require_integration_admin

  def create
    connector = WorkspaceConnector.find_by!(workspace: Current.workspace, provider: "notion", enabled: true)
    attributes = params.expect(notion_knowledge_connection: [ :name, :root_page_ids ])
    connection = NotionKnowledgeConnection.create!(workspace: Current.workspace, workspace_connector: connector,
      name: attributes[:name], root_page_ids: attributes[:root_page_ids].to_s.split(/[\s,]+/).reject(&:blank?))
    audit_event("connector.configured", subject: connection)
    redirect_to workspace_workspace_connectors_path(Current.workspace), notice: "Notion knowledge source added."
  rescue ActiveRecord::RecordInvalid
    redirect_to workspace_workspace_connectors_path(Current.workspace), alert: "Enter a name and 1 to 20 unique Notion page IDs."
  end

  def update
    connection = NotionKnowledgeConnection.find_by!(workspace: Current.workspace, id: params[:id])
    connection.update!(enabled: params.expect(notion_knowledge_connection: [ :enabled ]).fetch(:enabled))
    audit_event("connector.configured", subject: connection)
    redirect_to workspace_workspace_connectors_path(Current.workspace), notice: "Notion sync settings saved."
  end

  def sync
    connection = NotionKnowledgeConnection.find_by!(workspace: Current.workspace, id: params[:id])
    if connection.ready?
      NotionKnowledgeSyncJob.perform_later(connection.id)
      redirect_to workspace_workspace_connectors_path(Current.workspace), notice: "Notion knowledge sync queued."
    else
      redirect_to workspace_workspace_connectors_path(Current.workspace), alert: "Enable Notion and configure the Workspace service token first."
    end
  end

  private
    def require_integration_admin
      head :forbidden unless Current.require_membership!.can_configure_integrations?
    end
end
