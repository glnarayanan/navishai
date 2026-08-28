class CrewTasksController < ApplicationController
  include WorkspaceAuthorization

  before_action :require_workspace
  before_action :set_context
  before_action :set_task, only: %i[ show command ]

  rescue_from Current::RoleAccessDenied, with: :forbidden
  rescue_from CrewWork::InvalidCommand, ActiveRecord::RecordInvalid, with: :invalid_change

  helper_method :crew_tasks_path_for_scope, :crew_task_path_for_scope, :crew_task_command_path,
    :crew_task_runs_path, :crew_task_run_reconcile_path, :crew_task_searches_path,
    :crew_task_extractions_path

  def index
    load_workspace
  end

  def show
    load_workspace
  end

  def create
    profile = @workspace.agent_profiles.find(params[:agent_profile_id])
    task = CrewWork.create!(
      workspace: @workspace, membership: @membership, scope: @scope, profile:,
      title: params[:title], input_context: params[:input_context], expected_output: params[:expected_output],
      dependencies: params[:dependency_ids]
    )
    redirect_to crew_task_path_for_scope(task), notice: "Crew task created."
  end

  def command
    CrewWork.apply!(
      workspace: @workspace, membership: @membership, task: @task,
      command: params[:command_name], expected_sequence: params[:expected_sequence],
      attributes: command_attributes
    )
    redirect_to crew_task_path_for_scope(@task), notice: "Crew work record updated."
  end

  private
    def set_context
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

    def set_task
      @task = @scope.crew_tasks.find(params[:id])
    end

    def load_workspace
      @tasks = @scope.crew_tasks
        .includes(:assigned_agent_profile, :owner_user, :current_event, dependencies: :current_event)
        .order(created_at: :desc, id: :desc)
      @profiles = @workspace.agent_profiles.joins(:crew_template)
        .where(crew_templates: { crew_kind: @account ? :customer_success : :support })
        .includes(:current_version).order(:id)
      @events = @task&.events&.includes(:actor_user, :from_agent_profile, :to_agent_profile)&.order(sequence_number: :desc)
      if @task
        @runs = @task.execution_runs
          .includes(:current_event, crew_artifact: :resolution_contract_version)
          .order(attempt_number: :desc).to_a
        @active_run = @runs.find(&:active?)
        @public_web_searches = @task.public_web_searches
          .includes(:requested_by_user, results: :extractions).order(created_at: :desc, id: :desc)
      end
    end

    def command_attributes
      params.permit(:body, :evidence_kind, :evidence_locator, :agent_profile_id, :review_outcome)
    end

    def invalid_change(error)
      @command_error = error.message
      load_workspace
      render(@task ? :show : :index, status: :unprocessable_content)
    end

    def forbidden
      render "shared/permission_denied", status: :forbidden
    end

    def crew_tasks_path_for_scope
      @account ? workspace_account_crew_tasks_path(@workspace, @account) :
        workspace_support_case_crew_tasks_path(@workspace, @support_case)
    end

    def crew_task_path_for_scope(task)
      @account ? workspace_account_crew_task_path(@workspace, @account, task) :
        workspace_support_case_crew_task_path(@workspace, @support_case, task)
    end

    def crew_task_command_path(task)
      @account ? command_workspace_account_crew_task_path(@workspace, @account, task) :
        command_workspace_support_case_crew_task_path(@workspace, @support_case, task)
    end

    def crew_task_runs_path(task)
      @account ? workspace_account_crew_task_execution_runs_path(@workspace, @account, task) :
        workspace_support_case_crew_task_execution_runs_path(@workspace, @support_case, task)
    end

    def crew_task_run_reconcile_path(task, run)
      @account ? reconcile_workspace_account_crew_task_execution_run_path(@workspace, @account, task, run) :
        reconcile_workspace_support_case_crew_task_execution_run_path(@workspace, @support_case, task, run)
    end

    def crew_task_searches_path(task)
      @account ? workspace_account_crew_task_public_web_searches_path(@workspace, @account, task) :
        workspace_support_case_crew_task_public_web_searches_path(@workspace, @support_case, task)
    end

    def crew_task_extractions_path(task, result)
      @account ? workspace_account_crew_task_public_web_search_result_public_web_extractions_path(@workspace, @account, task, result) :
        workspace_support_case_crew_task_public_web_search_result_public_web_extractions_path(@workspace, @support_case, task, result)
    end
end
