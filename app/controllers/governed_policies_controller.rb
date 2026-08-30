class GovernedPoliciesController < ApplicationController
  include WorkspaceAuthorization

  before_action :require_workspace
  before_action :require_policy_admin

  def show
    load_page
  end

  def propose
    workspace = Current.require_workspace!
    family = workspace.resolution_contract_families.find(policy_params.fetch(:resolution_contract_family_id))
    profile = workspace.agent_profiles.find(policy_params.fetch(:agent_profile_id))
    scope_kind = policy_params.fetch(:scope_kind)
    proposal = GovernedPolicyChange.propose!(
      workspace:, membership: Current.require_membership!, family:, profile:, scope_kind:,
      scope_ids: policy_params.fetch("#{scope_kind}_ids", []),
      contract_attributes: policy_params.fetch(:contract).to_h,
      profile_attributes: policy_params.fetch(:profile).to_h,
      reason: policy_params.fetch(:reason)
    )
    redirect_to workspace_governed_policy_path(workspace, anchor: "proposal-#{proposal.id}"),
      notice: "Policy proposal saved. Preview the affected work before publishing."
  rescue GovernedPolicyChange::InvalidChange, KeyError => error
    render_error(error.message)
  end

  def preview
    workspace = Current.require_workspace!
    proposal = workspace.governed_policy_proposals.find(params[:proposal_id])
    preview = GovernedPolicyChange.preview!(
      workspace:, membership: Current.require_membership!, proposal:
    )
    redirect_to workspace_governed_policy_path(workspace, anchor: "preview-#{preview.id}"),
      notice: "Preview complete. Review each decision and its supporting evidence."
  rescue GovernedPolicyChange::InvalidChange => error
    render_error(error.message)
  end

  def publish
    workspace = Current.require_workspace!
    proposal = workspace.governed_policy_proposals.find(params[:proposal_id])
    preview = proposal.previews.find(params.require(:preview_id))
    publication = GovernedPolicyChange.publish!(
      workspace:, membership: Current.require_membership!, proposal:, preview:
    )
    redirect_to workspace_governed_policy_path(workspace, anchor: "publication-#{publication.id}"),
      notice: "Limited rollout published. Work outside its selected scope keeps the current policy."
  rescue GovernedPolicyChange::InvalidChange => error
    render_error(error.message, status: :conflict)
  end

  def rollback
    workspace = Current.require_workspace!
    publication = workspace.governed_policy_publications.find(params[:publication_id])
    rollback = GovernedPolicyChange.rollback!(
      workspace:, membership: Current.require_membership!, publication:,
      expected_publication_id: params.require(:expected_publication_id),
      reason: params.require(:reason)
    )
    redirect_to workspace_governed_policy_path(workspace, anchor: "publication-#{rollback.id}"),
      notice: "Rollback recorded for future decisions. Completed work was not changed."
  rescue GovernedPolicyChange::InvalidChange, ActionController::ParameterMissing => error
    render_error(error.message, status: :conflict)
  end

  private
    def require_policy_admin
      head :forbidden unless Current.require_membership!.can_configure_agents?
    end

    def policy_params
      params.expect(governed_policy: [
        :resolution_contract_family_id, :agent_profile_id, :scope_kind, :reason,
        { support_case_ids: [], account_ids: [], agent_profile_ids: [],
          contract: [ :execution_budget_units, :missing_items_block,
            { required_claim_categories: [], mandatory_review_checks: [], evidence_freshness_days: {} } ],
          profile: [ :runtime_profile_key, :timeout_seconds, :max_steps, :max_tool_calls,
            :review_policy, { fallback_profile_keys: [] } ] }
      ])
    end

    def render_error(message, status: :unprocessable_content)
      @policy_error = message
      load_page
      render :show, status:
    end

    def load_page
      workspace = Current.require_workspace!
      @families = workspace.resolution_contract_families.includes(:current_version).order(:family_key)
      @profiles = workspace.agent_profiles.includes(:current_version, :crew_template).order(:id)
      @current_cases = workspace.support_cases.where.not(status: :closed).order(updated_at: :desc).limit(20)
      @accounts = workspace.accounts.order(:name).limit(20)
      @proposals = workspace.governed_policy_proposals
        .includes(:resolution_contract_family, :agent_profile, :subjects, previews: :publication)
        .order(id: :desc).limit(20)
      @publications = workspace.governed_policy_publications
        .includes(:successor, proposal: :subjects).order(id: :desc).limit(20)
    end
end
