class AgentProfilesController < ApplicationController
  include WorkspaceAuthorization

  before_action :require_workspace
  before_action :require_agent_admin

  def update
    workspace = Current.require_workspace!
    crew = workspace.crew_templates.find(params[:crew_template_id])
    profile = crew.agent_profiles.find(params[:id])
    CrewConfiguration.update_profile!(
      workspace:, membership: Current.require_membership!, agent_profile: profile,
      attributes: profile_params.to_h.symbolize_keys
    )
    redirect_to workspace_crew_templates_path(workspace, anchor: "profile-#{profile.id}"),
      notice: "#{profile.name} policy updated."
  rescue CrewConfiguration::InvalidConfiguration => error
    @profile_error = error.message
    @editing_profile_id = params[:id].to_i
    @submitted_profile_attributes = profile_params.to_h
    load_crews
    render "crew_templates/index", status: :unprocessable_content
  end

  private
    def require_agent_admin
      head :forbidden unless Current.require_membership!.can_configure_agents?
    end

    def profile_params
      params.expect(agent_profile: [
        :expected_version_number, :instructions, :runtime_profile_key, :timeout_seconds, :max_steps,
        :max_tool_calls, :review_policy, :memory_required,
        { allowed_tools: [], fallback_profile_keys: [] }
      ])
    end

    def load_crews
      workspace = Current.require_workspace!
      @crews = workspace.crew_templates
        .includes(agent_profiles: { current_version: :created_by_user })
        .order(:id)
      @can_configure = true
    end
end
