class RecordedTarget
  class Error < StandardError; end
  VERSION = "recorded-support-v1"

  def self.validate!(trace_item:)
    raise Error, "Choose an unexpired trace record from this corpus." unless trace_item
    SupportTrace.payload(trace_item)
  rescue CorpusIntake::Invalid => error
    raise Error, error.message
  end

  def self.validate_input!(trace_item:, input:)
    trace = validate!(trace_item:)
    raise Error, "Recorded replay needs identical situation, known facts and permitted knowledge, including references. This output was not produced for the selected case input. Choose a matching case or run the agent again." unless input == trace["input"]
    trace
  end

  def self.call(trace_item:, input:)
    validate_input!(trace_item:, input:).fetch("output").deep_dup
  end
end
