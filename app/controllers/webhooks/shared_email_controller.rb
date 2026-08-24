class Webhooks::SharedEmailController < ActionController::API
  MAX_TIMESTAMP_SKEW = 5.minutes

  rate_limit to: 60, within: 1.minute, by: -> { request.remote_ip }, with: -> { head :too_many_requests }

  def create
    inbox = SharedEmailInbox.active.find_by!(webhook_key: params[:webhook_key])
    raw_email = request.raw_post.b
    return head :content_too_large if raw_email.bytesize > InboundEmailDelivery::MAX_BYTES
    return head :unauthorized unless valid_signature?(inbox, raw_email)

    delivery = SharedEmailIntake.receive!(inbox: inbox, raw_email: raw_email)
    render json: { id: delivery.id, status: delivery.status }, status: :accepted
  rescue SharedEmailIntake::Conflict
    head :conflict
  rescue SharedEmailIntake::ProcessingError
    head :unprocessable_content
  end

  private
    def valid_signature?(inbox, raw_email)
      secret = inbox.webhook_secret
      timestamp = Integer(request.headers["X-NavishAI-Timestamp"], exception: false)
      signature = request.headers["X-NavishAI-Signature"].to_s
      return false if secret.to_s.bytesize < 32 || timestamp.nil? || (Time.current.to_i - timestamp).abs > MAX_TIMESTAMP_SKEW

      expected = OpenSSL::HMAC.hexdigest("SHA256", secret, "#{timestamp}.#{raw_email}")
      signature.bytesize == expected.bytesize && ActiveSupport::SecurityUtils.secure_compare(signature, expected)
    end
end
