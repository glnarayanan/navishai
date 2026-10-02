class EvaluationRunItem < ImmutableRecord
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :evaluation_run
  belongs_to :eval_case
  has_one :evaluation_result
end
