class ReliabilityCockpitsController < ApplicationController
  include WorkspaceAuthorization

  before_action :require_workspace
  before_action :require_operator

  rescue_from Current::RoleAccessDenied, with: :forbidden

  def show
    @cockpit = ReliabilityCockpit.build(workspace: @workspace, membership: @membership)
  end

  def reconcile_run
    run = @workspace.execution_runs.find(params[:run_id])
    ReliabilityRecovery.reconcile_run!(workspace: @workspace, membership: @membership, run:)
    redirect_to workspace_reliability_cockpit_path(@workspace, anchor: "run-#{run.id}"),
      notice: "Runner admission reconciled."
  rescue ReliabilityRecovery::InvalidAction => error
    redirect_to workspace_reliability_cockpit_path(@workspace, anchor: "run-#{params[:run_id]}"),
      alert: error.message
  rescue RunnerClient::Error
    redirect_to workspace_reliability_cockpit_path(@workspace, anchor: "run-#{params[:run_id]}"),
      alert: "The runner still has no definite admission result. The saved run is unchanged."
  end

  def retry_run
    run = @workspace.execution_runs.find(params[:run_id])
    ReliabilityRecovery.retry_run!(workspace: @workspace, membership: @membership, run:)
    redirect_to workspace_reliability_cockpit_path(@workspace, anchor: "run-#{run.id}"),
      notice: "A new run attempt was requested."
  rescue ReliabilityRecovery::InvalidAction => error
    redirect_to workspace_reliability_cockpit_path(@workspace, anchor: "run-#{params[:run_id]}"),
      alert: error.message
  rescue RunnerClient::Error
    redirect_to workspace_reliability_cockpit_path(@workspace, anchor: "run-#{params[:run_id]}"),
      alert: "The retry is saved, but admission is unconfirmed. Reconcile that new run before retrying again."
  end

  def reconstruct_memory
    count = ReliabilityRecovery.reconstruct_memory!(workspace: @workspace, membership: @membership)
    record_label = count == 1 ? "record" : "records"
    redirect_to workspace_reliability_cockpit_path(@workspace, anchor: "memory"),
      notice: "Queued #{count} Memory #{record_label} for safe reindexing."
  end

  private
    def require_operator
      @workspace = Current.require_workspace!
      @membership = Current.require_membership!
      raise Current::RoleAccessDenied unless @membership.can_manage_work?
    end

    def forbidden
      head :forbidden
    end
end
