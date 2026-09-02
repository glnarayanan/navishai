class ExecutionRunsController < ApplicationController
  include WorkspaceAuthorization
  include CrewTaskRouteContext

  before_action :require_workspace
  before_action :set_crew_task_route_context

  rescue_from Current::RoleAccessDenied, with: :forbidden
  rescue_from ExecutionRecovery::InvalidAction, with: :invalid_action

  helper_method :crew_task_runs_path, :crew_task_run_reconcile_path

  def index
    load_runs
    render partial: "crew_tasks/execution_runs"
  end

  def create
    ExecutionRecovery.request!(
      workspace: @workspace, membership: @membership, task: @task,
      request_key: params[:request_key]
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

    def crew_task_runs_path(task)
      @account ? workspace_account_crew_task_execution_runs_path(@workspace, @account, task) :
        workspace_support_case_crew_task_execution_runs_path(@workspace, @support_case, task)
    end

    def crew_task_run_reconcile_path(task, run)
      @account ? reconcile_workspace_account_crew_task_execution_run_path(@workspace, @account, task, run) :
        reconcile_workspace_support_case_crew_task_execution_run_path(@workspace, @support_case, task, run)
    end
end
