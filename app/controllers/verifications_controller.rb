class VerificationsController < ApplicationController
  allow_unauthenticated_access
  before_action :set_user
  rescue_from ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound,
    with: :invalid_token

  def show
  end

  def update
    @user.with_lock do
      @user.update!(verified_at: Time.current)
      audit_event("email_verification.completed", workspace: nil, actor: @user, subject: @user)
    end
    redirect_to new_session_path, notice: "Email address verified. You can now sign in."
  end

  private
    def set_user
      @user = User.find_by_token_for!(:email_verification, params[:token])
    end

    def invalid_token
      redirect_to new_session_path, alert: "Verification link is invalid or has expired."
    end
end
