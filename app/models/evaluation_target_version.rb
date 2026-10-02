class EvaluationTargetVersion < ImmutableRecord
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :evaluation_target
  belongs_to :created_by, class_name: "User"
  validates :adapter, inclusion: { in: %w[scripted] }
  validate -> { ScriptedTarget.validate!(configuration) }

  def call(input:)
    raise EvalCase::Invalid, "Target processing version is not available." unless processing_version == ScriptedTarget::VERSION
    ScriptedTarget.call(configuration:, input:)
  end
end
