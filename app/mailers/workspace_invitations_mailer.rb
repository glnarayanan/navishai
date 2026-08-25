class WorkspaceInvitationsMailer < ApplicationMailer
  def invite(invitation)
    @invitation = invitation
    @token = invitation.generate_token_for(:acceptance)
    mail subject: "Join #{invitation.workspace.name} on NavishAI", to: invitation.email_address
  end
end
