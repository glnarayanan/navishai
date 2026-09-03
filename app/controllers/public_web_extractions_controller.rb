class PublicWebExtractionsController < ApplicationController
  include WorkspaceAuthorization
  include CrewTaskRouteContext

  before_action :require_workspace
  before_action :set_crew_task_route_context
  before_action :set_result
  rate_limit to: 20, within: 1.hour, by: -> { Current.user&.id || request.remote_ip },
    with: -> { head :too_many_requests }

  rescue_from Current::RoleAccessDenied, with: :forbidden

  def create
    extraction = PublicWebExtractionWorkflow.perform!(
      workspace: @workspace, membership: @membership, task: @task, result: @result,
      request_key: params[:request_key]
    )
    redirect_to task_path,
      notice: extraction.completed? ? "Page text is ready for review." : nil,
      alert: extraction.failed? ? "The page could not be extracted safely." : nil
  rescue PublicWebExtractionWorkflow::Error => error
    redirect_to task_path, alert: error.message
  end

  private
    def set_result
      @result = @workspace.public_web_search_results.joins(:public_web_search)
        .where(public_web_searches: { crew_task_id: @task.id, status: "completed" })
        .find(params[:public_web_search_result_id])
    end
end
