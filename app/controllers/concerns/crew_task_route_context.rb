module CrewTaskRouteContext
  extend ActiveSupport::Concern

  private
    def set_crew_task_route_context
      @workspace = Current.require_workspace!
      @membership = Current.require_membership!
      if params[:account_id]
        @account = @workspace.accounts.find(params[:account_id])
        @task = @account.crew_tasks.find(params[:crew_task_id])
      else
        @support_case = @workspace.support_cases.find(params[:support_case_id])
        @task = @support_case.crew_tasks.find(params[:crew_task_id])
      end
    end

    def task_path
      @account ? workspace_account_crew_task_path(@workspace, @account, @task) :
        workspace_support_case_crew_task_path(@workspace, @support_case, @task)
    end
end
