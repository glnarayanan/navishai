class AssumptionImpactInput < ImmutableRecord
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :assumption_impact
  belongs_to :scenario_version
end
