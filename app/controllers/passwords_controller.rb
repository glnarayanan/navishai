class PasswordsController < ApplicationController
  allow_unauthenticated_access
  before_action :set_user_by_token, only: %i[ edit update ]
  rate_limit(**SecurityRateLimits::AUTHENTICATION, only: :create, with: -> { redirect_to new_password_path, alert: "Try again later." })

  def new
  end

  def create
    if (user = User.find_by(email_address: params[:email_address])) && !user.break_glass?
      PasswordsMailer.reset(user).deliver_later
      audit_event("password_reset.requested", workspace: nil, actor: nil, subject: user)
    end

    redirect_to new_session_path, notice: "Password reset instructions sent (if user with that email address exists)."
  end

  def edit
  end

  def update
    @user.with_lock do
      User.find_by_password_reset_token!(params[:token])
      password_attributes = params.permit(:password, :password_confirmation)
        .merge(verified_at: @user.verified_at || Time.current)
      @user.update!(password_attributes)
      @user.sessions.active.update_all(revoked_at: Time.current)
      audit_event("password_reset.completed", workspace: nil, actor: @user, subject: @user)
    end
    redirect_to new_session_path, notice: "Password has been reset."
  rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound
    redirect_to new_password_path, alert: "Password reset link is invalid or has expired."
  rescue ActiveRecord::RecordInvalid
    redirect_to edit_password_path(token: params[:token]), alert: "Passwords did not match."
  end

  private
    def set_user_by_token
      @user = User.find_by_password_reset_token!(params[:token])
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      redirect_to new_password_path, alert: "Password reset link is invalid or has expired."
    end
end
