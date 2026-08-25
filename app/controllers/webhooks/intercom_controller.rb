class Webhooks::IntercomController < ActionController::API
  rate_limit to: 120, within: 1.minute, by: -> { request.remote_ip }, with: -> { head :too_many_requests }

  def create
    connection = IntercomConnection.active.find_by!(webhook_key: params[:webhook_key])
    return head :content_too_large if request.content_length.to_i > IntercomWebhookDelivery::MAX_BYTES

    raw_payload = request.body.read(IntercomWebhookDelivery::MAX_BYTES + 1).to_s.b
    return head :content_too_large if raw_payload.bytesize > IntercomWebhookDelivery::MAX_BYTES
    return head :unauthorized unless valid_signature?(connection, raw_payload)

    delivery = IntercomSync.receive!(connection: connection, raw_payload: raw_payload)
    render json: { id: delivery.id, status: delivery.status }, status: :accepted
  rescue IntercomSync::InvalidPayload
    head :unprocessable_content
  end

  private
    def valid_signature?(connection, raw_payload)
      signature = request.headers["X-Hub-Signature"].to_s
      expected = "sha1=#{OpenSSL::HMAC.hexdigest('SHA1', connection.client_secret.to_s, raw_payload)}"
      connection.client_secret.to_s.bytesize >= 32 && signature.bytesize == expected.bytesize &&
        ActiveSupport::SecurityUtils.secure_compare(signature, expected)
    end
end
