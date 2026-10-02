class SupportOutput
  class Invalid < StandardError; end
  MAX_BYTES = 100.kilobytes
  KEYS = %w[messages tool_calls collected_fields citations escalation policy_branch].freeze

  def self.validate!(data)
    valid = data.is_a?(Hash) && data.keys.sort == KEYS.sort && data.to_json.bytesize <= MAX_BYTES && !data.to_json.include?("\\u0000") &&
      data["messages"].is_a?(Array) && data["messages"].size.between?(1, 100) && data["messages"].all? { |message| message.is_a?(Hash) && message.keys.sort == %w[content role] && %w[assistant user].include?(message["role"]) && message["content"].is_a?(String) } &&
      data["tool_calls"].is_a?(Array) && data["tool_calls"].size <= 100 && data["tool_calls"].all? { |call| call.is_a?(Hash) && call.keys.sort == %w[arguments name] && call["name"].is_a?(String) && call["arguments"].is_a?(Hash) } &&
      data["collected_fields"].is_a?(Hash) && data["citations"].is_a?(Array) && data["citations"].size <= 100 && data["citations"].all? { |citation| citation.is_a?(Hash) && citation.keys.sort == %w[quote reference] && citation.values.all? { |value| value.is_a?(String) } } &&
      data["escalation"].is_a?(Hash) && data["escalation"].keys.sort == %w[team triggered] && [ true, false ].include?(data["escalation"]["triggered"]) && (data["escalation"]["team"].nil? || data["escalation"]["team"].is_a?(String)) &&
      (data["policy_branch"].nil? || data["policy_branch"].is_a?(String))
    raise Invalid, "Use support-output-v1 JSON with messages, tool_calls, collected_fields, citations, escalation and policy_branch (at most 100 KiB)." unless valid

    data
  end
end
