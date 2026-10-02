class ScenarioReview < ImmutableRecord
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :scenario_version
  belongs_to :reviewed_by, class_name: "User"
  belongs_to :merged_version, class_name: "ScenarioVersion", optional: true
  validates :decision, inclusion: { in: %w[approve reject merge] }
  validates :note, length: { maximum: 2000 }
  validate -> { errors.add(:note, "cannot contain null bytes") if note.to_s.include?("\0") }
end
