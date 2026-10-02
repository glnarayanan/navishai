class HttpTarget
  VERSION = "http-support-v1"
  PROTOCOL = "support-target-v1"
  Error = EvaluationHttp::Error

  def self.validate!(configuration, workspace_id:)
    EvaluationHttp.validate!(configuration, workspace_id:)
  end

  def self.call(configuration:, input:, workspace_id:, request_key:)
    response = EvaluationHttp.call(configuration:, payload: { "schema" => PROTOCOL, "input" => input }, workspace_id:, request_key:)
    SupportOutput.validate!(response)
  end
end
