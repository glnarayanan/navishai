class EvalSuiteCase < ApplicationRecord
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :eval_suite
  belongs_to :eval_case
end
