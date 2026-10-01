class ModelGateway
  def self.valid_configuration?(execution)
    return false unless execution.is_a?(Hash) && execution.keys.sort == %w[endpoint model settings]
    return false unless execution["model"].is_a?(String) && execution["model"].match?(/\A[a-zA-Z0-9][a-zA-Z0-9._:\/-]{0,119}\z/)
    settings = execution["settings"]
    return false unless settings.is_a?(Hash) && settings.keys.sort == %w[max_output_tokens seed temperature] && settings["temperature"] == 0 &&
      settings["max_output_tokens"].is_a?(Integer) && settings["max_output_tokens"].between?(256, 4096) && (settings["seed"].nil? || (settings["seed"].is_a?(Integer) && settings["seed"].between?(0, 2**31 - 1)))
    EvaluationHttp.endpoint(execution["endpoint"])
    true
  rescue SupportOutput::Invalid
    false
  end

  def self.valid_report?(usage, cost)
    (usage.nil? || (usage.is_a?(Hash) && usage.keys.sort == %w[input_tokens output_tokens] && usage.values.all? { |value| value.is_a?(Integer) && value.between?(0, 10**9) })) &&
      (cost.nil? || (cost.is_a?(Hash) && cost.keys.sort == %w[currency micro_units] && cost["currency"].is_a?(String) && cost["currency"].match?(/\A[A-Z]{3}\z/) && cost["micro_units"].is_a?(Integer) && cost["micro_units"].between?(0, 10**12)))
  end
end
