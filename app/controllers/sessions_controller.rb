class SessionsController < ApplicationController
  allow_unauthenticated_access only: %i[ new create ]
  rate_limit(**SecurityRateLimits::AUTHENTICATION, only: :create, with: -> { redirect_to new_session_path, alert: "Try again later." })

  def new
  end

  def create
    if user = User.find_by(email_address: params[:email_address])
      destination = user.with_lock do
        next unless user.authenticate(params[:password]) && user.sign_in_allowed?

        start_new_session_for(user).tap do
          audit_event("authentication.succeeded", workspace: nil, actor: user, subject: Current.session, metadata: { method: "local" })
        end
      end
      if destination
        redirect_to destination, status: :see_other
      else
        audit_event("authentication.failed", workspace: nil, actor: nil, metadata: { method: "local" })
        redirect_to new_session_path, alert: "Try another email address or password."
      end
    else
      User.authenticate_by(params.permit(:email_address, :password))
      audit_event("authentication.failed", workspace: nil, actor: nil, metadata: { method: "local" })
      redirect_to new_session_path, alert: "Try another email address or password."
    end
  end

  def destroy
    Session.transaction do
      audit_event("authentication.signed_out", workspace: nil, subject: Current.session)
      terminate_session
    end
    redirect_to new_session_path, status: :see_other
  end
end
