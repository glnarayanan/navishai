class EvalCase < ImmutableRecord
  class Invalid < StandardError; end
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :scenario_version
  belongs_to :scenario_review
  belongs_to :compiled_by, class_name: "User"
  has_many :eval_case_checks

  def eligible!
    version = scenario_version.reload
    expected = contract.flat_map { |kind, statements| statements.each_index.map { |index| [ kind, index ] } }.sort
    actual = eval_case_checks.pluck(:requirement_kind, :requirement_index).sort
    raise Invalid, "This case needs the current approved scenario version, complete checks and unexpired, current document evidence." unless version.scenario.current_version_id == version.id && version.approved? && !version.expired? && !version.stale? && !corpus.eval_definitions_expired? && actual == expected
  end
end
