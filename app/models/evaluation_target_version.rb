class EvaluationTargetVersion < ImmutableRecord
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :evaluation_target
  belongs_to :created_by, class_name: "User"
  validates :adapter, inclusion: { in: %w[scripted http] }
  validate :validate_configuration

  def call(input:, request_key:)
    case [ adapter, processing_version ]
    when [ "scripted", ScriptedTarget::VERSION ] then ScriptedTarget.call(configuration:, input:)
    when [ "http", HttpTarget::VERSION ] then HttpTarget.call(configuration:, input:, workspace_id:, request_key:)
    else raise EvalCase::Invalid, "Target processing version is not available."
    end
  end

  private
    def validate_configuration
      case adapter
      when "scripted" then ScriptedTarget.validate!(configuration)
      when "http" then HttpTarget.validate!(configuration, workspace_id:)
      end
    end
end
