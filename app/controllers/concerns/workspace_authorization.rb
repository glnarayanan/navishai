module WorkspaceAuthorization
  extend ActiveSupport::Concern

  private
    def select_workspace(workspace)
      Current.workspace = Current.user.workspaces.active.find(workspace.id)
      cookies.signed[:workspace_id] = {
        value: workspace.id,
        httponly: true,
        secure: Rails.env.production?,
        same_site: :lax
      }
    end

    def require_workspace
      workspace_id = params[:workspace_id] || cookies.signed[:workspace_id]
      select_workspace(Current.user.workspaces.active.find(workspace_id))
    end

    def require_role(*roles)
      Current.require_role!(*roles)
    rescue Current::RoleAccessDenied
      head :forbidden
    end
end
