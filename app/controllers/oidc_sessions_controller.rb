require "base64"
require "digest"

class OidcSessionsController < ApplicationController
  FLOW_TTL = 10.minutes

  allow_unauthenticated_access
  rate_limit(**SecurityRateLimits::AUTHENTICATION, with: -> { redirect_to new_session_path, alert: "Try again later." })

  def create
    oidc_provider = provider
    state = SecureRandom.urlsafe_base64(32)
    nonce = SecureRandom.urlsafe_base64(32)
    verifier = SecureRandom.urlsafe_base64(64)
    return_to = session.delete(:return_to_after_authenticating)
    reset_session
    session[:oidc_flow] = {
      "state" => state, "nonce" => nonce, "verifier" => verifier,
      "created_at" => Time.current.to_i, "return_to" => return_to
    }
    challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
    redirect_to oidc_provider.authorization_url(
      redirect_uri: oidc_session_callback_url, state:, nonce:, code_challenge: challenge
    ), allow_other_host: true
  rescue OidcProvider::Error
    failed!
  end

  def callback
    flow = session.delete(:oidc_flow).to_h
    state = params[:state].to_s
    valid_flow = flow["created_at"].to_i >= FLOW_TTL.ago.to_i && secure_equal?(state, flow["state"])
    raise OidcProvider::Error, "OIDC flow is invalid" unless valid_flow && params[:error].blank?

    user = provider.authenticate!(
      code: params[:code], code_verifier: flow.fetch("verifier"),
      redirect_uri: oidc_session_callback_url, nonce: flow.fetch("nonce")
    )
    session[:return_to_after_authenticating] = flow["return_to"] if flow["return_to"].present?
    destination = start_new_session_for(user, authentication_method: :oidc)
    audit_event("authentication.succeeded", workspace: nil, actor: user, subject: Current.session, metadata: { method: "oidc" })
    redirect_to destination, status: :see_other
  rescue OidcProvider::Error, KeyError
    failed!
  end

  private
    def provider
      OidcProvider.new(transport: Rails.application.config.x.oidc_transport)
    end

    def secure_equal?(left, right)
      left = left.to_s
      right = right.to_s
      left.bytesize == right.bytesize && ActiveSupport::SecurityUtils.secure_compare(left, right)
    end

    def failed!
      reset_session
      audit_event("authentication.failed", workspace: nil, actor: nil, metadata: { method: "oidc" })
      redirect_to new_session_path, alert: "Single sign-on could not be completed."
    end
end
