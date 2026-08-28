class OutcomeExplanationsController < ApplicationController
  include WorkspaceAuthorization

  before_action :require_workspace

  def show
    @workspace = Current.require_workspace!
    @membership = Current.require_membership!
    @explanation = OutcomeExplanation.resolve!(
      workspace: @workspace, membership: @membership,
      subject_type: params[:subject_type], subject_id: params[:subject_id]
    )
  rescue ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished => error
    Rails.logger.error("Outcome explanation load failed: #{error.class}")
    render :error, status: :service_unavailable
  end
end
