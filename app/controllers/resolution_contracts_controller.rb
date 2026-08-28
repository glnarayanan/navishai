class ResolutionContractsController < ApplicationController
  include WorkspaceAuthorization

  before_action :require_workspace
  before_action :require_contract_admin

  def update
    workspace = Current.require_workspace!
    family = workspace.resolution_contract_families.find(params[:id])
    raise ResolutionContractConfiguration::InvalidConfiguration,
      "Resolution policy now requires an immutable proposal, retained-fact preview, and explicit canary. Use Governed policy."
  rescue ResolutionContractConfiguration::InvalidConfiguration => error
    @contract_error = error.message
    @editing_contract_id = params[:id].to_i
    @submitted_contract_attributes = contract_params.to_h
    load_crews
    render "crew_templates/index", status: :unprocessable_content
  end

  private
    def require_contract_admin
      head :forbidden unless Current.require_membership!.can_configure_agents?
    end

    def contract_params
      params.expect(resolution_contract: [
        :expected_current_version_id, :execution_budget_units, :missing_items_block,
        { required_claim_categories: [], mandatory_review_checks: [], evidence_freshness_days: {} }
      ])
    end

    def load_crews
      workspace = Current.require_workspace!
      @resolution_contracts = workspace.resolution_contract_families.includes(:current_version).order(:family_key)
      @crews = workspace.crew_templates
        .includes(agent_profiles: { current_version: :created_by_user })
        .order(:id)
      @can_configure = true
    end
end
