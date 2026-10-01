class ModelFailureMatchingCandidate < ImmutableRecord
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :model_failure_matching
  belongs_to :scenario_version
end
