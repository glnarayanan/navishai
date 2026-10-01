class HttpConversationTarget
  VERSION = "http-conversation-v1"
  PROTOCOL = "support-conversation-v1"

  def self.call(configuration:, input:, plan:, workspace_id:, request_key:, execution:)
    raise SupportOutput::Invalid, "Conversation plans allow at most ten follow-ups." unless plan.is_a?(Array) && plan.size <= 10
    history = [ { "role" => "user", "content" => input.fetch("situation") } ]
    aggregate = nil
    execution["turns"] = []
    execution["termination_reason"] = "error"
    (0..plan.size).each do |index|
      yield
      payload = { "schema" => PROTOCOL, "input" => input, "history" => history }
      key = Digest::SHA256.hexdigest("#{request_key}/turn/#{index}")
      receipt = { "turn_index" => index, "request_key" => key, "input_digest" => Digest::SHA256.hexdigest(payload.to_json), "outcome" => "unknown" }
      execution["turns"] << receipt
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        reply = EvaluationHttp.call(configuration:, payload:, workspace_id:, request_key: key)
        yield
        SupportOutput.validate!(reply)
        raise SupportOutput::Invalid, "Conversation responses must contain assistant messages only." unless reply.fetch("messages").all? { |message| message["role"] == "assistant" }
        receipt["outcome"] = "validated"
      rescue SupportOutput::Invalid
        receipt["outcome"] = "invalid_output"
        raise
      ensure
        receipt["elapsed_ms"] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      end
      history.concat(reply.fetch("messages"))
      aggregate ||= reply.merge("tool_calls" => [], "citations" => [], "collected_fields" => {})
      aggregate["tool_calls"] += reply.fetch("tool_calls")
      aggregate["citations"] += reply.fetch("citations")
      aggregate["collected_fields"].merge!(reply.fetch("collected_fields"))
      aggregate["escalation"] = reply.fetch("escalation")
      aggregate["policy_branch"] = reply.fetch("policy_branch")
      aggregate["messages"] = history
      SupportOutput.validate!(aggregate)
      next_step = plan[index]
      unless next_step
        execution["termination_reason"] = "plan_complete"
        break
      end
      unless reply.fetch("messages").map { |message| message.fetch("content") }.join("\n").downcase.include?(next_step.fetch("after_assistant_contains").downcase)
        execution["termination_reason"] = "condition_unmet"
        break
      end
      history << { "role" => "user", "content" => next_step.fetch("message") }
      SupportOutput.validate!(aggregate)
    end
    aggregate
  rescue StandardError
    execution["termination_reason"] = "error"
    raise
  end
end
