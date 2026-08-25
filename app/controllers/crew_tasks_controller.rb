class CrewTasksController < ApplicationController
  include WorkspaceAuthorization

  before_action :require_workspace
  before_action :set_context
  before_action :set_task, only: %i[ show command ]

  rescue_from Current::RoleAccessDenied, with: :forbidden
  rescue_from CrewWork::InvalidCommand, ActiveRecord::RecordInvalid, with: :invalid_change

  def index
    load_workspace
  end

  def show
    load_workspace
  end

  def create
    profile = @workspace.agent_profiles.find(params[:agent_profile_id])
    task = CrewWork.create!(
      workspace: @workspace, membership: @membership, scope: @support_case, profile:,
      title: params[:title], input_context: params[:input_context], expected_output: params[:expected_output],
      dependencies: params[:dependency_ids]
    )
    redirect_to workspace_support_case_crew_task_path(@workspace, @support_case, task),
      notice: "Crew task created."
  end

  def command
    CrewWork.apply!(
      workspace: @workspace, membership: @membership, task: @task,
      command: params[:command_name], expected_sequence: params[:expected_sequence],
      attributes: command_attributes
    )
    redirect_to workspace_support_case_crew_task_path(@workspace, @support_case, @task),
      notice: "Crew work record updated."
  end

  private
    def set_context
      @workspace = Current.require_workspace!
      @membership = Current.require_membership!
      @support_case = @workspace.support_cases.includes(conversation: :contact).find(params[:support_case_id])
    end

    def set_task
      @task = @support_case.crew_tasks.find(params[:id])
    end

    def load_workspace
      @tasks = @support_case.crew_tasks
        .includes(:assigned_agent_profile, :owner_user, :current_event, dependencies: :current_event)
        .order(created_at: :desc, id: :desc)
      @profiles = @workspace.agent_profiles.joins(:crew_template)
        .where(crew_templates: { crew_kind: :support }).includes(:current_version).order(:id)
      @events = @task&.events&.includes(:actor_user, :from_agent_profile, :to_agent_profile)&.order(sequence_number: :desc)
      if @task
        @runs = @task.execution_runs.includes(:current_event, :crew_artifact).order(attempt_number: :desc).to_a
        @active_run = @runs.find(&:active?)
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
end
