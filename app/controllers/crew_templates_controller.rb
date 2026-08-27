class CrewTemplatesController < ApplicationController
  include WorkspaceAuthorization

  before_action :require_workspace

  def index
    load_crews
  end

  private
    def load_crews
      workspace = Current.require_workspace!
      @resolution_contracts = workspace.resolution_contract_families.includes(:current_version).order(:family_key)
      @crews = workspace.crew_templates
        .includes(agent_profiles: { current_version: :created_by_user })
        .order(:id)
      @can_configure = Current.require_membership!.can_configure_agents?
    end
end
