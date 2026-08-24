class Webhooks::RunnerEventsController < ActionController::API
  MAX_TIMESTAMP_SKEW = 5.minutes

  rate_limit to: 600, within: 1.minute, by: -> { request.remote_ip }, with: -> { head :too_many_requests }

  def create
    return head :content_too_large if request.content_length.to_i > RunnerProtocol::MAX_BODY_BYTES

    body = request.body.read(RunnerProtocol::MAX_BODY_BYTES + 1).to_s.b
    return head :content_too_large if body.bytesize > RunnerProtocol::MAX_BODY_BYTES
    return head :unauthorized unless valid_signature?(body)
    return head :unsupported_media_type unless request.media_type == "application/json"

    workspace = Workspace.find_by!(runner_key: request.headers["X-NavishAI-Workspace-Key"])
    event = RunnerProtocol::CanonicalEvent.parse(body)
    record = ExecutionLedger.ingest!(workspace:, event:)
    render json: { event_id: record.event_key, sequence: record.sequence_number }, status: :accepted
  rescue RunnerProtocol::MalformedMessage, ExecutionLedger::InvalidRun
    head :unprocessable_content
  rescue ExecutionLedger::EventConflict, ExecutionLedger::OutOfOrder
    head :conflict
  end

  private
    def valid_signature?(body)
      secret = ENV["NAVISHAI_RUNNER_SHARED_SECRET"].to_s.b
      timestamp = Integer(request.headers["X-NavishAI-Timestamp"], exception: false)
      signature = request.headers["X-NavishAI-Signature"].to_s
      return false if secret.bytesize < 32 || timestamp.nil? || (Time.current.to_i - timestamp).abs > MAX_TIMESTAMP_SKEW

      expected = RunnerProtocol.signature(
        secret:, timestamp: timestamp.to_s, method: request.request_method,
        path: request.path, body:
      )
      signature.bytesize == expected.bytesize && ActiveSupport::SecurityUtils.secure_compare(signature, expected)
    end
end
