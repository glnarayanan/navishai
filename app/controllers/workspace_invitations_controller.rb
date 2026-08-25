class WorkspaceInvitationsController < ApplicationController
  include WorkspaceAuthorization

  before_action :require_workspace
  before_action :expire_invitations, only: %i[ index create ]
  before_action :require_invitation_manager, only: :index

  def index
    @invitations = Current.require_workspace!.workspace_invitations.order(created_at: :desc)
    @invitation = WorkspaceInvitation.new
    @available_roles = available_roles
  end

  def create
    actor = Current.require_membership!
    return head :forbidden unless actor.can_invite_role?(invitation_params[:role])

    invitation = Current.require_workspace!.workspace_invitations.create!(
      invitation_params.merge(status: :pending, invited_by: Current.user)
    )
    WorkspaceInvitationsMailer.invite(invitation).deliver_later
    redirect_to workspace_workspace_invitations_path(Current.workspace), notice: "Invitation sent."
  rescue ActiveRecord::RecordInvalid => error
    @invitations = Current.workspace.workspace_invitations.order(created_at: :desc)
    @invitation = error.record
    @available_roles = available_roles
    render :index, status: :unprocessable_content
  end

  def destroy
    invitation = Current.require_workspace!.workspace_invitations.pending.find(params[:id])
    return head :forbidden unless Current.require_membership!.can_invite_role?(invitation.role)

    invitation.revoke!
    redirect_to workspace_workspace_invitations_path(Current.workspace), notice: "Invitation revoked."
  end

  private
    def expire_invitations
      Current.require_workspace!.workspace_invitations.expire_pending!
    end

    def require_invitation_manager
      require_role(:owner, :admin)
    end

    def invitation_params
      params.expect(workspace_invitation: [ :email_address, :role ])
    end

    def available_roles
      actor = Current.require_membership!
      Membership::ROLES.select { |role| actor.can_invite_role?(role) }
    end
end
