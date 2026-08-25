class PublicWebSearchesController < ApplicationController
  include WorkspaceAuthorization

  before_action :require_workspace
  before_action :set_context
  rate_limit to: 30, within: 1.hour, by: -> { Current.user&.id || request.remote_ip },
    with: -> { head :too_many_requests }

  rescue_from Current::RoleAccessDenied, with: :forbidden

  def create
    search = PublicWebResearch.perform!(
      workspace: @workspace, membership: @membership, task: @task,
      query: params[:public_web_query], request_key: params[:request_key]
    )
    redirect_to workspace_support_case_crew_task_path(@workspace, @support_case, @task),
      notice: search.completed? ? "Public-web results are ready for review." : "Public-web search recorded."
  rescue RunnerClient::AmbiguousResult
    redirect_to workspace_support_case_crew_task_path(@workspace, @support_case, @task),
      alert: "The runner outcome is not yet known. Retry the same search to reconcile it."
  rescue RunnerClient::Error, PublicWebResearch::Error => error
    redirect_to workspace_support_case_crew_task_path(@workspace, @support_case, @task), alert: error.message
  end

  private
    def set_context
      @workspace = Current.require_workspace!
      @membership = Current.require_membership!
      @support_case = @workspace.support_cases.find(params[:support_case_id])
      @task = @support_case.crew_tasks.find(params[:crew_task_id])
    end

    def forbidden
      render "shared/permission_denied", status: :forbidden
    end
end
