class ModelFailureMatchingResult < ImmutableRecord
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :model_failure_matching
  self.filter_attributes += [ :result ]
  validate -> { errors.add(:result, "must contain suggestions or an execution error") unless result.is_a?(Hash) && %w[suggestions error].include?(result["decision"]) }
end
