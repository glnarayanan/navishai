class PublicWebExtractionsController < ApplicationController
  include WorkspaceAuthorization

  before_action :require_workspace
  before_action :set_context
  rate_limit to: 20, within: 1.hour, by: -> { Current.user&.id || request.remote_ip },
    with: -> { head :too_many_requests }

  rescue_from Current::RoleAccessDenied, with: :forbidden

  def create
    extraction = PublicWebExtractionWorkflow.perform!(
      workspace: @workspace, membership: @membership, task: @task, result: @result,
      request_key: params[:request_key]
    )
    redirect_to workspace_support_case_crew_task_path(@workspace, @support_case, @task),
      notice: extraction.completed? ? "Page text is ready for review." : nil,
      alert: extraction.failed? ? "The page could not be extracted safely." : nil
  rescue PublicWebExtractionWorkflow::Error => error
    redirect_to workspace_support_case_crew_task_path(@workspace, @support_case, @task), alert: error.message
  end

  private
    def set_context
      @workspace = Current.require_workspace!
      @membership = Current.require_membership!
      @support_case = @workspace.support_cases.find(params[:support_case_id])
      @task = @support_case.crew_tasks.find(params[:crew_task_id])
      @result = @workspace.public_web_search_results.joins(:public_web_search)
        .where(public_web_searches: { crew_task_id: @task.id, status: "completed" })
        .find(params[:public_web_search_result_id])
    end

    def forbidden
      render "shared/permission_denied", status: :forbidden
    end
end
