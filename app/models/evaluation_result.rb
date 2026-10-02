class EvaluationResult < ImmutableRecord
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :evaluation_run_item
  belongs_to :eval_case
  has_many :regression_cases
  validates :status, inclusion: { in: %w[pass fail incomplete error] }

  def add_regression!(membership:, suite_id:, rationale:)
    corpus.with_lock do
      corpus.authorize_writer!(membership)
      suite = corpus.eval_suites.find(suite_id)
      raise EvalCase::Invalid, "Only a reported behavioural failure can enter a regression suite." unless status == "fail" && suite.kind == "regression"
      suite.add_case!(membership:, case_id: eval_case_id)
      existing = regression_cases.find_by(eval_suite: suite)
      return existing if existing
      record = regression_cases.create!(workspace:, corpus:, eval_suite: suite, eval_case:, reviewed_by: membership.user, rationale:, created_at: Time.current)
      AuditEvent.record!(action: "regression.reviewed", source: :web, workspace:, actor: membership.user, subject: record)
      record
    end
  end
end
