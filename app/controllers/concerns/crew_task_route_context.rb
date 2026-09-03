module CrewTaskRouteContext
  extend ActiveSupport::Concern

  included do
    helper_method :crew_task_runs_path, :crew_task_run_reconcile_path
  end

  private
    def set_crew_task_scope
      @workspace = Current.require_workspace!
      @membership = Current.require_membership!
      if params[:account_id]
        @account = @workspace.accounts.find(params[:account_id])
        @scope = @account
      else
        @support_case = @workspace.support_cases.includes(conversation: :contact).find(params[:support_case_id])
        @scope = @support_case
      end
    end

    def set_crew_task_route_context
      set_crew_task_scope
      @task = @scope.crew_tasks.find(params[:crew_task_id])
    end

    def task_path
      @account ? workspace_account_crew_task_path(@workspace, @account, @task) :
        workspace_support_case_crew_task_path(@workspace, @support_case, @task)
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
