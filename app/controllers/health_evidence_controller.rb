class HealthEvidenceController < ApplicationController
  include WorkspaceAuthorization

  before_action :require_workspace

  def show
    workspace = Current.require_workspace!
    account = workspace.accounts.find(params[:id])
    assessment = account.health_assessments.find(params[:assessment_id])
    signal = assessment.signals.find_by!(signal_key: params[:signal_key])
    @evidence = HealthEvidence.new(workspace:, account:, assessment:, signal:)
  end
end
