module MemoryEngine
  Health = Data.define(:available, :detail) do
    def available?
      available
    end
  end

  Document = Data.define(
    :workspace_key, :memory_key, :memory_type, :scope_kind, :scope_key, :content,
    :source_reference, :observed_at, :valid_from, :valid_until, :confidence
  ) do
    def self.from(record)
      new(
        workspace_key: record.workspace.runner_key,
        memory_key: record.memory_key,
        memory_type: record.memory_type,
        scope_kind: record.scope_kind,
        scope_key: record.scope_target.id.to_s,
        content: record.content,
        source_reference: record.source_reference,
        observed_at: record.observed_at,
        valid_from: record.valid_from,
        valid_until: record.valid_until,
        confidence: record.confidence.to_f
      )
    end
  end

  Query = Data.define(:workspace_key, :text, :scope_filters, :limit) do
    def initialize(workspace_key:, text:, scope_filters:, limit:)
      raise ArgumentError, "query text is required" if text.blank?
      raise ArgumentError, "limit must be between 1 and 50" unless limit in 1..50

      super
    end
  end

  Hit = Data.define(:memory_key, :score)

  class Adapter
    def health
      raise NotImplementedError
    end

    def index(document:)
      raise NotImplementedError
    end

    def search(query:)
      raise NotImplementedError
    end

    def remove(workspace_key:, memory_key:)
      raise NotImplementedError
    end
  end
end
