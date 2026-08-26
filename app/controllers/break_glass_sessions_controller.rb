class BreakGlassSessionsController < ApplicationController
  allow_unauthenticated_access
  before_action :require_local_request
  rate_limit(**SecurityRateLimits::SENSITIVE, only: :create, with: -> { head :too_many_requests })

  def new
  end

  def create
    return head :not_found unless valid_deployment_token?(params[:deployment_token])

    user = User.find_by(email_address: params[:email_address])
    destination = user&.with_lock do
      next unless user.authenticate(params[:password]) && user.break_glass? && user.verified?

      start_new_session_for(user).tap do
        audit_event("authentication.succeeded", workspace: nil, actor: user, subject: Current.session, metadata: { method: "break_glass" })
      end
    end
    if destination
      redirect_to destination, status: :see_other
    else
      User.authenticate_by(params.permit(:email_address, :password)) unless user
      audit_event("authentication.failed", workspace: nil, actor: nil, metadata: { method: "break_glass" })
      redirect_to new_break_glass_session_path, alert: "Try another email address or password."
    end
  end

  private
    def require_local_request
      head :not_found unless direct_local_request? && ENV["NAVISHAI_BREAK_GLASS_TOKEN"].present?
    end

    def direct_local_request?
      request.local? && %w[
        Forwarded
        X-Forwarded-For
        X-Forwarded-Host
        X-Forwarded-Port
        X-Forwarded-Proto
        X-Real-IP
      ].none? { |header| request.headers[header].present? }
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
