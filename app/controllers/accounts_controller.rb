class AccountsController < ApplicationController
  include WorkspaceAuthorization

  before_action :require_workspace
  before_action :set_context
  before_action :set_account, except: :index
  before_action :require_writer, only: %i[ recalculate request_risk_review start_risk_review ]
  before_action :require_manager, only: :resolve_risk_review

  rescue_from Current::RoleAccessDenied, with: :forbidden
  rescue_from AccountRiskWorkflow::InvalidCommand, with: :invalid_change

  def index
    @accounts = @workspace.accounts.includes(:contacts, health_assessments: :risk_investigation).order(:name)
  end

  def show
    load_account
  end

  def recalculate
    AccountHealth.recalculate!(workspace: @workspace, account: @account,
      trigger_kind: "human_request", membership: @membership)
    redirect_to workspace_account_path(@workspace, @account), notice: "Account health recalculated from current facts."
  end

  def request_risk_review
    assessment = AccountHealth.recalculate!(workspace: @workspace, account: @account,
      trigger_kind: "human_request", membership: @membership)
    redirect_to workspace_account_path(@workspace, @account, anchor: "risk-reviews"),
      notice: assessment.risk_investigation ? "Risk review opened from a fresh health snapshot." :
        "A risk review is already open. The health snapshot was refreshed."
  end

  def start_risk_review
    investigation = @account.risk_investigations.find(params[:investigation_id])
    result = AccountRiskWorkflow.start!(workspace: @workspace, membership: @membership, investigation:)
    redirect_to workspace_account_crew_task_path(@workspace, @account, result.crew_task),
      notice: "Risk investigation started."
  end

  def resolve_risk_review
    investigation = @account.risk_investigations.find(params[:investigation_id])
    AccountRiskWorkflow.resolve!(workspace: @workspace, membership: @membership, investigation:)
    redirect_to workspace_account_path(@workspace, @account, anchor: "risk-reviews"),
      notice: "Risk review resolved."
  end

  private
    def set_context
      @workspace = Current.require_workspace!
      @membership = Current.require_membership!
    end

    def set_account
      @account = @workspace.accounts.find(params[:id])
    end

    def load_account
      @contacts = @account.contacts.order(:name, :id)
      @assessment = @account.health_assessments.includes(:signals).first
      @history = @account.health_assessments.limit(12)
      @investigations = @account.risk_investigations
        .includes(:account_health_assessment, crew_task: [ :assigned_agent_profile, :artifacts ])
        .order(opened_at: :desc, id: :desc)
      @tasks = @account.crew_tasks.includes(:assigned_agent_profile, :current_event).order(created_at: :desc).limit(8)
    end

    def require_writer
      raise Current::RoleAccessDenied unless @membership.can_write?
    end

    def require_manager
      raise Current::RoleAccessDenied unless @membership.can_manage_work?
    end

    def invalid_change(error)
      @command_error = error.message
      load_account
      render :show, status: :unprocessable_content
    end

    def forbidden
      render "shared/permission_denied", status: :forbidden
    end
end
