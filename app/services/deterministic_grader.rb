class DeterministicGrader
  VERSION = "support-checks-v1"
  TYPES = %w[tool_called forbidden_tool field_collected citation_present escalation policy_branch text_contains text_absent tool_before].freeze

  def self.valid_definition?(definition)
    definition.is_a?(Hash) && definition.keys.sort == %w[type value] && TYPES.include?(definition["type"]) &&
      (definition["type"] == "tool_before" ? definition["value"].is_a?(Array) && definition["value"].size == 2 && definition["value"].uniq.size == 2 && definition["value"].all? { |value| value.is_a?(String) && value.strip.length.between?(1, 500) } : definition["value"].is_a?(String) && definition["value"].strip.length.between?(1, 500))
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
    when "tool_before" then tools.include?(expected[0]) && tools.include?(expected[1]) && tools.index(expected[0]) < tools.index(expected[1])
    end
    { "decision" => passed ? "pass" : "fail", "reason" => "#{type}: #{passed ? 'condition met' : 'condition not met'}", "confidence" => nil, "check_type" => type, "expected" => expected }
  end
end
