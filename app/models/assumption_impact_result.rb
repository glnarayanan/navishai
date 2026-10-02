class AssumptionImpactResult < ImmutableRecord
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :assumption_impact
end
