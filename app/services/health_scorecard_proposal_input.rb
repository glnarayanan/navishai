class HealthScorecardProposalInput
  EXPECTED_OUTPUT = "JSON object only: schema_version 1, kind scorecard_proposal, definition " \
    "(the scorecard schema or null), explanation, assumptions[], unsupported_requests[], missing_evidence[]. " \
    "Map only catalog signals and integer weights 1-100. Bands must satisfy 1 <= watch < healthy <= 99. " \
    "Total weight cannot exceed 200. Do not calculate scores. Do not invent signals, formulas, SQL, code, or extra commands."

  def self.build(workspace:, scorecard:, prompt:, parent_proposal: nil)
    definition = scorecard.current_version.definition
    catalog = HealthScorecardDefinition::CATALOG.map do |key, entry|
      "#{key} weight 1-100 default #{entry.fetch(:default_weight)} — #{entry.fetch(:label)}. #{entry.fetch(:detail)}"
    end
    observed = workspace.account_health_signals.distinct.order(:signal_key).pluck(:signal_key)
    payload = {
      "task" => parent_proposal ? "scorecard_proposal_revision" : "scorecard_proposal",
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
    payload["parent_proposal"] = parent_payload(parent_proposal) if parent_proposal
    instruction = parent_proposal ?
      "Revise the previous scorecard proposal. Keep lineage. The model never calculates authoritative health." :
      "Propose a Workspace health scorecard configuration. The model never calculates authoritative health."
    context = "#{instruction}\n#{JSON.generate(payload)}"
    raise ArgumentError, "Scorecard proposal context exceeds the task limit." if context.bytesize > 8_000

    context
  end

  def self.parent_payload(parent)
    {
      "proposal_id" => parent.id,
      "run_key" => parent.execution_run.run_key,
      "adapter" => parent.execution_run.selected_adapter_key,
      "prompt" => parent.prompt.truncate_bytes(500, omission: ""),
      "definition" => parent.proposed_definition,
      "validation_status" => parent.validation_status
    }
  end
  private_class_method :parent_payload
end
