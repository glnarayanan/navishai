class EvalCaseCheck < ImmutableRecord
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :eval_case
  belongs_to :scenario_version
  belongs_to :scenario_evidence
  belongs_to :grader_version

  def requirement
    eval_case.contract.fetch(requirement_kind).fetch(requirement_index)
  end
end
