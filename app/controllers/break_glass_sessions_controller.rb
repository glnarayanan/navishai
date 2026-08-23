class BreakGlassSessionsController < ApplicationController
  allow_unauthenticated_access
  before_action :require_local_request
  rate_limit to: 5, within: 10.minutes, only: :create, with: -> { head :too_many_requests }

  def new
  end

  def create
    return head :not_found unless valid_deployment_token?(params[:deployment_token])

    user = User.authenticate_by(params.permit(:email_address, :password))
    if user&.break_glass? && user.verified?
      redirect_to start_new_session_for(user), status: :see_other
    else
      redirect_to new_break_glass_session_path, alert: "Try another email address or password."
    end
  end

  private
    def require_local_request
      head :not_found unless request.local? && ENV["NAVISHAI_BREAK_GLASS_TOKEN"].present?
    end

    def valid_deployment_token?(candidate)
      expected = ENV["NAVISHAI_BREAK_GLASS_TOKEN"].to_s
      return false if candidate.blank? || expected.bytesize < 32

      ActiveSupport::SecurityUtils.secure_compare(
        Digest::SHA256.hexdigest(candidate),
        Digest::SHA256.hexdigest(expected)
      )
    end
end
