class WorkspaceInvitationAcceptancesController < ApplicationController
  allow_unauthenticated_access

  before_action :set_invitation

  def show
    authenticated?
    @existing_user = User.exists?(email_address: @invitation.email_address)
  end

  def create
    authenticated?
    user = ApplicationRecord.transaction do
      @invitation.accept!(
        user: Current.user,
        password: params[:password],
        password_confirmation: params[:password_confirmation]
      ).tap do |accepted_user|
        audit_event("workspace_invitation.accepted", workspace: @invitation.workspace, actor: accepted_user, subject: @invitation, metadata: { role: @invitation.role })
      end
    end
    destination = Current.user ? workspace_path(@invitation.workspace) : start_new_session_for(user)
    redirect_to destination, notice: "You joined #{@invitation.workspace.name}.", status: :see_other
  rescue WorkspaceInvitation::AuthenticationRequired
    session[:return_to_after_authenticating] = workspace_invitation_acceptance_path(token: params[:token])
    redirect_to new_session_path, alert: "Sign in with the invited email address to continue."
  rescue WorkspaceInvitation::AcceptanceError, ActiveRecord::RecordInvalid => error
    redirect_to workspace_invitation_acceptance_path(token: params[:token]), alert: error.message
  end

  private
    def set_invitation
      @invitation = WorkspaceInvitation.find_by_token_for!(:acceptance, params[:token])
    rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound
      redirect_to new_session_path, alert: "Invitation link is invalid or has expired."
    end
end
