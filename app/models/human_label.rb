class HumanLabel < ImmutableRecord
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :calibration_sample
  belongs_to :labelled_by, class_name: "User"
  validates :decision, inclusion: { in: %w[pass fail uncertain] }
  validates :rationale, presence: true, length: { maximum: 2000 }
  validate -> { errors.add(:rationale, "cannot contain null bytes") if rationale.to_s.include?("\0") }
end
