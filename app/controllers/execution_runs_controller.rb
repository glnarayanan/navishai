class ExecutionRunsController < ApplicationController
  include WorkspaceAuthorization

  before_action :require_workspace
  before_action :set_context

  rescue_from Current::RoleAccessDenied, with: :forbidden
  rescue_from ExecutionRecovery::InvalidAction, with: :invalid_action

  def index
    load_runs
    render partial: "crew_tasks/execution_runs"
  end

  def create
    ExecutionRecovery.request!(
      workspace: @workspace, membership: @membership, task: @task,
      request_key: params[:request_key]
    )
    redirect_to workspace_support_case_crew_task_path(@workspace, @support_case, @task),
      notice: "Specialist run requested."
  rescue RunnerClient::Error
    redirect_to workspace_support_case_crew_task_path(@workspace, @support_case, @task),
      alert: "The run is saved, but the runner did not confirm admission. Check the run details and retry the connection."
  end

  def reconcile
    run = @task.execution_runs.find(params[:id])
    ExecutionRecovery.reconcile!(
      workspace: @workspace, membership: @membership, task: @task, run:
    )
    redirect_to workspace_support_case_crew_task_path(@workspace, @support_case, @task),
      notice: "Runner admission reconciled."
  rescue RunnerClient::Error
    redirect_to workspace_support_case_crew_task_path(@workspace, @support_case, @task),
      alert: "The runner still did not confirm admission. The saved run is unchanged and safe to check again."
  end

  private
    def set_context
      @workspace = Current.require_workspace!
      @membership = Current.require_membership!
      @support_case = @workspace.support_cases.find(params[:support_case_id])
      @task = @support_case.crew_tasks.find(params[:crew_task_id])
    end

    def load_runs
      @runs = @task.execution_runs.includes(:current_event, :crew_artifact).order(attempt_number: :desc).to_a
      @active_run = @runs.find(&:active?)
    end

    def invalid_action(error)
      @command_error = error.message
      load_runs
      render partial: "crew_tasks/execution_runs", status: :unprocessable_content
    end

    def forbidden
      render "shared/permission_denied", status: :forbidden
    end
end
