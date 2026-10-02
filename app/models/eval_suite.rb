class EvalSuite < ApplicationRecord
  belongs_to :workspace
  belongs_to :corpus
  has_many :eval_suite_cases
  has_many :eval_cases, through: :eval_suite_cases
  validates :name, presence: true, length: { maximum: 120 }
  validates :kind, inclusion: { in: %w[evaluation regression] }

  def add_case!(membership:, case_id:)
    corpus.with_lock do
      corpus.authorize_writer!(membership)
      item = corpus.eval_cases.find(case_id)
      item.eligible!
      raise EvalCase::Invalid, "A suite contains at most 50 cases in this first batch runner." if eval_suite_cases.count >= 50 && !eval_cases.exists?(item.id)
      eval_suite_cases.find_or_create_by!(workspace:, corpus:, eval_case: item)
    end
  end
end
