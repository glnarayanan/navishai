class ScriptedTarget
  VERSION = "scripted-support-v1"
  MAX_BYTES = 1.megabyte

  def self.validate!(configuration)
    valid = configuration.is_a?(Hash) && configuration.keys.sort == %w[default_output rules] && configuration.to_json.bytesize <= MAX_BYTES && !configuration.to_json.include?("\\u0000") &&
      configuration["rules"].is_a?(Array) && configuration["rules"].size <= 20 && configuration["rules"].all? do |rule|
        rule.is_a?(Hash) && rule.keys.sort == %w[equals fact output] && rule["fact"].is_a?(String) && rule["fact"].strip.length.between?(1, 100) &&
          [ String, Numeric, TrueClass, FalseClass, NilClass ].any? { |type| rule["equals"].is_a?(type) }
      end
    raise SupportOutput::Invalid, "Use scripted-support-v1: rules (at most 20 fact/equals/output rules) and default_output, at most 1 MiB. This fixture cannot run code." unless valid
    SupportOutput.validate!(configuration["default_output"])
    configuration["rules"].each { |rule| SupportOutput.validate!(rule["output"]) }
  end

  def self.call(configuration:, input:)
    validate!(configuration)
    rule = configuration["rules"].find { |candidate| input.fetch("known_facts").key?(candidate["fact"]) && input.fetch("known_facts")[candidate["fact"]] == candidate["equals"] }
    (rule ? rule["output"] : configuration["default_output"]).deep_dup
  end
end
