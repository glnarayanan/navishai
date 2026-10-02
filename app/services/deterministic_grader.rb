class DeterministicGrader
  VERSION = "support-checks-v2"
  RESPONSE_TYPES = %w[assistant_response_contains assistant_response_absent].freeze
  PAIR_TYPES = [ "tool_before", *RESPONSE_TYPES ].freeze
  TYPES = %w[tool_called forbidden_tool field_collected citation_present escalation policy_branch text_contains text_absent tool_before].concat(RESPONSE_TYPES).freeze

  def self.valid_definition?(definition)
    return false unless definition.is_a?(Hash) && definition.keys.sort == %w[type value] && TYPES.include?(definition["type"])
    type, value = definition.values_at("type", "value")
    return value.is_a?(String) && value.strip.length.between?(1, 500) unless PAIR_TYPES.include?(type)

    value.is_a?(Array) && value.size == 2 && (type != "tool_before" || value.uniq.size == 2) && value.all? do |part|
      part.is_a?(String) && part.strip.present? && (type == "tool_before" ? part.strip.length : part.length) <= 500
    end
  end

  def self.call(definition:, output:, knowledge: [])
    SupportOutput.validate!(output)
    raise SupportOutput::Invalid, "Invalid deterministic check definition." unless valid_definition?(definition)

    type, expected = definition.values_at("type", "value")
    tools = output["tool_calls"].map { |call| call["name"] }
    text = output["messages"].select { |message| message["role"] == "assistant" }.map { |message| message["content"] }.join("\n")
    passed = case type
    when "tool_called" then tools.include?(expected)
    when "forbidden_tool" then !tools.include?(expected)
    when "field_collected" then output["collected_fields"].key?(expected) && (output["collected_fields"][expected] == false || output["collected_fields"][expected].present?)
    when "citation_present"
      output["citations"].any? { |citation| citation["reference"] == expected && citation["quote"].present? && knowledge.any? { |source| source["reference"] == expected && source["content"].include?(citation["quote"]) } }
    when "escalation" then output["escalation"] == { "triggered" => true, "team" => expected }
    when "policy_branch" then output["policy_branch"] == expected
    when "text_contains" then text.downcase.include?(expected.downcase)
    when "text_absent" then !text.downcase.include?(expected.downcase)
    when *RESPONSE_TYPES then response_matches?(output["messages"], expected, absent: type == "assistant_response_absent")
    when "tool_before" then tools.include?(expected[0]) && tools.include?(expected[1]) && tools.index(expected[0]) < tools.index(expected[1])
    end
    { "decision" => passed ? "pass" : "fail", "reason" => "#{type}: #{passed ? 'condition met' : 'condition not met'}", "confidence" => nil, "check_type" => type, "expected" => expected }
  end

  def self.response_matches?(messages, expected, absent:)
    anchor, phrase = expected.map(&:downcase)
    matches = messages.each_index.select { |index| messages[index]["role"] == "user" && messages[index]["content"].downcase.include?(anchor) }
    matches.any? && matches.all? do |index|
      response = messages.drop(index + 1).take_while { |message| message["role"] == "assistant" }
      text = response.map { |message| message["content"] }.join("\n")
      text.present? && (text.downcase.include?(phrase) != absent)
    end
  end
  private_class_method :response_matches?
end
