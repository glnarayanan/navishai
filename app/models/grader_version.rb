class GraderVersion < ImmutableRecord
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :grader
  belongs_to :created_by, class_name: "User"
  validates :kind, inclusion: { in: %w[deterministic rubric_judge] }
  validate :explicit_definition

  private
    def explicit_definition
      valid = if kind == "deterministic"
        DeterministicGrader.valid_definition?(definition)
      else
        JudgeGrader.valid_definition?(definition)
      end
      errors.add(:definition, "must match the selected versioned grader schema") unless valid && !definition.to_json.include?("\\u0000")
    end
end
