class EvaluationTargetVersion < ImmutableRecord
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :evaluation_target
  belongs_to :created_by, class_name: "User"
  belongs_to :trace_item, class_name: "CorpusItem", optional: true
  validates :adapter, inclusion: { in: %w[scripted http recorded] }
  validate :validate_configuration

  def call(input:, request_key:)
    case [ adapter, processing_version ]
    when [ "scripted", ScriptedTarget::VERSION ] then ScriptedTarget.call(configuration:, input:)
    when [ "http", HttpTarget::VERSION ] then HttpTarget.call(configuration:, input:, workspace_id:, request_key:)
    when [ "recorded", RecordedTarget::VERSION ] then RecordedTarget.call(trace_item:, input:)
    else raise EvalCase::Invalid, "Target processing version is not available."
    end
  end

  private
    def validate_configuration
      case adapter
      when "scripted" then ScriptedTarget.validate!(configuration)
      when "http" then HttpTarget.validate!(configuration, workspace_id:)
      when "recorded"
        raise RecordedTarget::Error, "Recorded targets use a same-corpus trace record and no JSON configuration." unless configuration == {} && trace_item&.corpus_id == corpus_id && trace_item&.workspace_id == workspace_id
        RecordedTarget.validate!(trace_item:)
      end
    end
end
