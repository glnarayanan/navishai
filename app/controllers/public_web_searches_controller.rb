class PublicWebSearchesController < ApplicationController
  include WorkspaceAuthorization
  include CrewTaskRouteContext

  before_action :require_workspace
  before_action :set_crew_task_route_context
  rate_limit to: 30, within: 1.hour, by: -> { Current.user&.id || request.remote_ip },
    with: -> { head :too_many_requests }

  rescue_from Current::RoleAccessDenied, with: :forbidden

  def create
    search = PublicWebResearch.perform!(
      workspace: @workspace, membership: @membership, task: @task,
      query: params[:public_web_query], request_key: params[:request_key]
    )
    redirect_to task_path,
      notice: search.completed? ? "Public-web results are ready for review." : "Public-web search recorded."
  rescue RunnerClient::AmbiguousResult
    redirect_to task_path,
      alert: "The runner outcome is not yet known. Retry the same search to reconcile it."
  rescue RunnerClient::Error, PublicWebResearch::Error => error
    redirect_to task_path, alert: error.message
  end

end
