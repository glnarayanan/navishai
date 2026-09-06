class ExecutionRunsController < ApplicationController
  include WorkspaceAuthorization
  include CrewTaskRouteContext
  include RunPanelFreshness

  before_action :require_workspace
  before_action :set_crew_task_route_context

  rescue_from Current::RoleAccessDenied, with: :forbidden
  rescue_from ExecutionRecovery::InvalidAction, with: :invalid_action

  def index
    response.set_header "ETag", run_panel_etag_value
    headers["Cache-Control"] = "private, no-store"
    if request.fresh?(response)
      head :not_modified
      return
    end

    load_runs
    render partial: "crew_tasks/execution_runs"
  end

  def create
    ExecutionRecovery.request!(
      workspace: @workspace, membership: @membership, task: @task,
      request_key: params[:request_key], personal_account_id: params[:personal_account_id]
    )
    redirect_to task_path, notice: "Specialist run requested."
  rescue RunnerClient::Error
    redirect_to task_path,
      alert: "The run is saved, but the runner did not confirm admission. Check the run details and retry the connection."
  end

  def reconcile
    run = @task.execution_runs.find(params[:id])
    ExecutionRecovery.reconcile!(
      workspace: @workspace, membership: @membership, task: @task, run:
    )
    redirect_to task_path, notice: "Runner admission reconciled."
  rescue RunnerClient::Error
    redirect_to task_path,
      alert: "The runner still did not confirm admission. The saved run is unchanged and safe to check again."
  end

  private
    def load_runs
      @runs = @task.execution_runs.includes(:current_event, :crew_artifact).order(attempt_number: :desc).to_a
      @active_run = @runs.find(&:active?)
    end

    def invalid_action(error)
      @command_error = error.message
      load_runs
      render partial: "crew_tasks/execution_runs", status: :unprocessable_content
    end
end
