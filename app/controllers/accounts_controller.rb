class AccountsController < ApplicationController
  include WorkspaceAuthorization

  before_action :require_workspace
  before_action :set_context
  before_action :set_account, except: :index
  before_action :require_writer, only: %i[ recalculate request_risk_review start_risk_review ]
  before_action :require_manager, only: %i[ resolve_risk_review resolve_identity ]

  rescue_from Current::RoleAccessDenied, with: :forbidden
  rescue_from AccountRiskWorkflow::InvalidCommand, with: :invalid_change

  def index
    @page = [ params[:page].to_i, 1 ].max
    records = @workspace.accounts.order(:name, :id).offset((@page - 1) * 50).limit(51).to_a
    @has_next_page = records.length > 50
    @accounts = records.first(50)
    account_ids = @accounts.map(&:id)
    @contact_counts = Contact.where(workspace: @workspace, account_id: account_ids).group(:account_id).count
    @assessments_by_account_id = @workspace.account_health_assessments
      .where(account_id: account_ids)
      .select("DISTINCT ON (account_id) account_health_assessments.*")
      .order(account_id: :asc, calculated_at: :desc, id: :desc)
      .index_by(&:account_id)
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

  def resolve_identity
    dossier = AccountDossier.new(workspace: @workspace, account: @account, membership: @membership)
    identity = dossier.identity!(params[:source_identity_id])
    target = identity.account? ? @workspace.accounts.find(params.require(:target_id)) :
      @workspace.contacts.find(params.require(:target_id))
    IdentityMatchReview.resolve!(
      workspace: @workspace, source_identity: identity, target:, membership: @membership
    )
    redirect_to workspace_account_path(@workspace, @account, anchor: "account-dossier"),
      notice: "Source identity resolved."
  rescue ActiveRecord::RecordInvalid, ArgumentError, ActionController::ParameterMissing => error
    @command_error = error.message
    load_account
    render :show, status: :unprocessable_content
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
      intervention_scope = @account.customer_success_interventions
      @intervention_count, @intervention_proposed_count, @intervention_overdue_count = intervention_scope.pick(
        Arel.sql("COUNT(*)"),
        Arel.sql("COUNT(*) FILTER (WHERE status = 'proposed')"),
        Arel.sql("COUNT(*) FILTER (WHERE status IN ('proposed', 'approved') AND target_on < CURRENT_DATE)")
      )
      @interventions = intervention_scope.includes(
        :account_health_assessment, :account_risk_investigation,
        { proposing_crew_artifact: :reviews },
        { accountable_membership: :user }, { proposed_by_membership: :user },
        { approved_by_membership: :user }, { completed_by_membership: :user },
        { abandoned_by_membership: :user },
        outcome_review: [ { reviewed_by_membership: :user }, :before_account_health_assessment,
          :after_account_health_assessment ]
      ).order(proposed_at: :desc, id: :desc).limit(50).to_a
      @intervention_review_assessments = @account.health_assessments.limit(50).to_a
      load_intervention_proposals
      @tasks = @account.crew_tasks.includes(:assigned_agent_profile, :current_event).order(created_at: :desc).limit(8)
      @dossier = AccountDossier.new(workspace: @workspace, account: @account, membership: @membership)
    end

    def load_intervention_proposals
      return @proposable_intervention_plans = [] unless @assessment && @membership.can_write?

      @intervention_origin_assessment = @assessment
      @intervention_origin_investigation = @investigations.find do |investigation|
        investigation.account_health_assessment_id == @intervention_origin_assessment.id
      end
      @proposable_intervention_plans = @workspace.crew_artifacts
        .includes(:reviews, :revisions, crew_task: :account)
        .joins(:crew_task)
        .where(artifact_kind: "intervention_plan", contract_result_state: "complete",
          crew_tasks: { account_id: @account.id })
        .where.missing(:customer_success_intervention)
        .order(created_at: :desc, id: :desc).limit(20).to_a
        .select do |artifact|
          CustomerSuccessInterventionWorkflow.proposal_ready?(
            account: @account, assessment: @intervention_origin_assessment,
            investigation: @intervention_origin_investigation, artifact:
          )
        end
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
