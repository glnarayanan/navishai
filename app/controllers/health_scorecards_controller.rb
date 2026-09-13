class HealthScorecardsController < ApplicationController
  include WorkspaceAuthorization

  before_action :require_workspace
  before_action :set_context
  before_action :require_writer, except: :show
  before_action :require_admin, only: %i[ publish rollback ]

  rescue_from Current::RoleAccessDenied, with: :forbidden
  rescue_from HealthScorecardDesigner::InvalidProposal,
    HealthScorecardProposalWorkflow::InvalidCommand,
    HealthScorecardBacktester::InvalidBacktest,
    HealthScorecardPublisher::InvalidPublish, with: :invalid_change

  def show
    load_scorecard
  end

  def propose
    version = HealthScorecardDesigner.propose!(workspace: @workspace, membership: @membership,
      prompt: params[:goal_prompt], healthy_min: params[:healthy_min], watch_min: params[:watch_min],
      weights: selected_weights)
    redirect_to workspace_health_scorecard_path(@workspace, version_id: version.id),
      notice: "Proposal saved as version #{version.version_number}. Run the preview before publishing."
  end

  def generate
    parent = if params[:parent_proposal_id].present?
      @workspace.health_scorecard_proposals.find(params[:parent_proposal_id])
    end
    HealthScorecardProposalWorkflow.generate!(
      workspace: @workspace, membership: @membership, prompt: params[:proposal_prompt],
      parent_proposal: parent, expected_latest_proposal_id: params[:expected_latest_proposal_id],
      admit: !Rails.env.test?
    )
    redirect_to workspace_health_scorecard_path(@workspace),
      notice: "A scorecard proposal run was submitted through the approved runtime. Generating a proposal does not publish or change scores."
  end

  def accept
    version = HealthScorecardProposalWorkflow.accept!(
      workspace: @workspace, membership: @membership,
      proposal: @workspace.health_scorecard_proposals.find(params[:proposal_id]),
      expected_proposal_id: params[:expected_proposal_id]
    )
    redirect_to workspace_health_scorecard_path(@workspace, version_id: version.id),
      notice: "Proposal accepted as unpublished version #{version.version_number}. Run the preview before publishing."
  end

  def backtest
    version = @workspace.health_scorecard.versions.find(params[:version_id])
    HealthScorecardBacktester.run!(workspace: @workspace, membership: @membership, version:)
    redirect_to workspace_health_scorecard_path(@workspace, version_id: version.id, anchor: "preview"),
      notice: "Preview and historical backtest saved."
  end

  def publish
    version = @workspace.health_scorecard.versions.find(params[:version_id])
    HealthScorecardPublisher.publish!(workspace: @workspace, membership: @membership, version:,
      expected_current_version_id: params[:expected_current_version_id])
    redirect_to workspace_health_scorecard_path(@workspace, version_id: version.id),
      notice: "Version #{version.version_number} now scores future account snapshots."
  end

  def rollback
    version = @workspace.health_scorecard.versions.find(params[:version_id])
    HealthScorecardPublisher.rollback!(workspace: @workspace, membership: @membership, version:,
      expected_current_version_id: params[:expected_current_version_id])
    redirect_to workspace_health_scorecard_path(@workspace, version_id: version.id),
      notice: "Future scoring rolled back to version #{version.version_number}."
  end

  private
    def set_context
      @workspace = Current.require_workspace!
      @membership = Current.require_membership!
    end

    def load_scorecard
      @scorecard = HealthScorecardDesigner.install_default!(workspace: @workspace)
      @versions = @scorecard.versions.includes(:backtests, :design_turns, :created_by_user, source_proposal: :execution_run)
        .order(version_number: :desc)
      @selected_version = params[:version_id].present? ? @versions.find(params[:version_id]) : @versions.first
      @backtest = @selected_version.backtests.order(generated_at: :desc, id: :desc).first
      @catalog = HealthScorecardDefinition::CATALOG
      @proposals = @scorecard.proposals.includes(
        :execution_run, :created_by_user,
        accepted_version: :created_by_user,
        parent_proposal: [ :execution_run, :created_by_user ]
      ).limit(20)
      @published_definition = @scorecard.current_version.definition
      @pending_proposal_run = @scorecard.crew_tasks.joins(:execution_runs)
        .merge(ExecutionRun.where(status: %w[admitting admitted running]))
        .order("execution_runs.created_at DESC", "execution_runs.id DESC").first
    end

    def selected_weights
      signal_params = params[:signals]
      return {} unless signal_params.is_a?(ActionController::Parameters)

      signal_params = signal_params.permit(HealthScorecardDefinition::CATALOG.keys.index_with { %i[ enabled weight ] })
      signal_params.to_h.filter_map do |key, values|
        [ key, values["weight"] ] if values["enabled"] == "1"
      end.to_h
    end

    def require_writer
      raise Current::RoleAccessDenied unless @membership.can_write?
    end

    def require_admin
      raise Current::RoleAccessDenied unless @membership.can_configure_agents?
    end

    def invalid_change(error)
      @command_error = error.message
      load_scorecard
      render :show, status: :unprocessable_content
    end
end
