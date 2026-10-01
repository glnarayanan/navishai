class ScenarioProposalResult < ImmutableRecord
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :scenario_proposal
  validate -> { errors.add(:result, "must contain a proposal, abstention or execution error") unless result.is_a?(Hash) && %w[proposal abstain error].include?(result["decision"]) }
end
