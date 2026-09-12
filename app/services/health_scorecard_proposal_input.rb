class HealthScorecardProposalInput
  EXPECTED_OUTPUT = "JSON object only: schema_version 1, kind scorecard_proposal, definition " \
    "(the scorecard schema or null), explanation, assumptions[], unsupported_requests[], missing_evidence[]. " \
    "Map only catalog signals and integer weights 1-100. Bands must satisfy 1 <= watch < healthy <= 99. " \
    "Total weight cannot exceed 200. Do not calculate scores. Do not invent signals, formulas, SQL, code, or extra commands."

  def self.build(workspace:, scorecard:, prompt:)
    definition = scorecard.current_version.definition
    catalog = HealthScorecardDefinition::CATALOG.map do |key, entry|
      "#{key} weight 1-100 default #{entry.fetch(:default_weight)} — #{entry.fetch(:label)}. #{entry.fetch(:detail)}"
    end
    observed = workspace.account_health_signals.distinct.order(:signal_key).pluck(:signal_key)
    payload = {
      "task" => "scorecard_proposal",
      "user_prompt" => prompt,
      "current_definition" => definition,
      "supported_signals" => catalog,
      "allowed_bands" => "1 <= watch_min < healthy_min <= 99",
      "available_data" => {
        "account_count" => workspace.accounts.count,
        "assessment_count" => workspace.account_health_assessments.count,
        "observed_signal_keys" => observed
      }
    }
    context = "Propose a Workspace health scorecard configuration. The model never calculates authoritative health.\n" \
      "#{JSON.generate(payload)}"
    raise ArgumentError, "Scorecard proposal context exceeds the task limit." if context.bytesize > 8_000

    context
  end
end
