class RegressionCase < ImmutableRecord
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :eval_suite
  belongs_to :eval_case
  belongs_to :evaluation_result
  belongs_to :reviewed_by, class_name: "User"
  validates :rationale, presence: true, length: { maximum: 2000 }
  validate -> { errors.add(:rationale, "cannot contain null bytes") if rationale.to_s.include?("\0") }
end
