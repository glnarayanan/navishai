class ScenarioEvidence < ImmutableRecord
  self.table_name = "scenario_evidence"
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :scenario_version
  belongs_to :corpus_item
  validates :kind, inclusion: { in: %w[expectation knowledge] }
  validates :excerpt, length: { in: 1..4000 }
  validate -> { errors.add(:excerpt, "must occur in its source record") unless corpus_item && corpus_item.content.include?(excerpt.to_s) }
end
