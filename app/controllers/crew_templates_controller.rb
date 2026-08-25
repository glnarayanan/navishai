class CrewTemplatesController < ApplicationController
  include WorkspaceAuthorization

  before_action :require_workspace

  def index
    load_crews
  end

  private
    def load_crews
      workspace = Current.require_workspace!
      @crews = workspace.crew_templates
        .includes(agent_profiles: { current_version: :created_by_user })
        .order(:id)
      @can_configure = Current.require_membership!.can_configure_agents?
    end
end
