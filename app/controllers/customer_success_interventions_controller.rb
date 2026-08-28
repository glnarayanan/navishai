class CustomerSuccessInterventionsController < ApplicationController
  include WorkspaceAuthorization

  before_action :require_workspace
  before_action :set_context
  before_action :set_intervention, except: :create

  rescue_from Current::RoleAccessDenied, with: :forbidden
  rescue_from CustomerSuccessInterventionWorkflow::InvalidCommand, with: :invalid_change

  def create
    investigation = @account.risk_investigations.find(params[:account_risk_investigation_id]) if
      params[:account_risk_investigation_id].present?
    assessment = investigation&.account_health_assessment ||
      @account.health_assessments.find(params.require(:account_health_assessment_id))
    artifact = @workspace.crew_artifacts.find(params.require(:proposing_crew_artifact_id))
    CustomerSuccessInterventionWorkflow.propose!(
      workspace: @workspace, membership: @membership, account: @account, assessment:,
      investigation:, artifact:, accountable_membership: @membership,
      expected_observable_change: params[:expected_observable_change],
      target_on: params[:target_on], reason: params[:reason]
    )
    redirect_to account_path, notice: "Proposed intervention recorded for human review."
  end

  def approve
    CustomerSuccessInterventionWorkflow.approve!(
      workspace: @workspace, membership: @membership, intervention: @intervention
    )
    redirect_to account_path, notice: "Intervention approved by a human Manager."
  end

  def complete
    CustomerSuccessInterventionWorkflow.complete!(
      workspace: @workspace, membership: @membership, intervention: @intervention
    )
    redirect_to account_path, notice: "Human completion recorded. No customer message was sent or scheduled."
  end

  def abandon
    CustomerSuccessInterventionWorkflow.abandon!(
      workspace: @workspace, membership: @membership, intervention: @intervention,
      reason: params[:reason]
    )
    redirect_to account_path, notice: "Intervention abandoned with a human decision."
  end

  def review
    assessment = @account.health_assessments.find(params.require(:after_account_health_assessment_id))
    CustomerSuccessInterventionWorkflow.review!(
      workspace: @workspace, membership: @membership, intervention: @intervention,
      after_assessment: assessment, uncertainty: params[:uncertainty]
    )
    redirect_to account_path, notice: "Observed outcome review frozen without a causal claim."
  end

  private
    def set_context
      @workspace = Current.require_workspace!
      @membership = Current.require_membership!
      @account = @workspace.accounts.find(params[:account_id])
    end

    def set_intervention
      @intervention = @account.customer_success_interventions.find(params[:id])
    end

    def account_path
      workspace_account_path(@workspace, @account, anchor: "customer-success-interventions")
    end

    def invalid_change(error)
      redirect_to account_path, alert: error.message
    end

    def forbidden
      render "shared/permission_denied", status: :forbidden
    end
end
