module MemoryEngine
  UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  Health = Data.define(:available, :detail) do
    def available?
      available
    end
  end

  Document = Data.define(
    :organization_key, :workspace_key, :memory_key, :memory_type, :scope_kind, :scope_key, :content,
    :source_reference, :observed_at, :valid_from, :valid_until, :confidence
  ) do
    def self.from(record)
      new(
        organization_key: record.workspace.organization_id.to_s,
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

  ScopeFilter = Data.define(:kind, :key) do
    def initialize(kind:, key:)
      raise ArgumentError, "scope kind is invalid" unless kind.to_s.in?(MemoryRecord::SCOPE_KINDS)
      raise ArgumentError, "scope key is required" if key.to_s.blank?

      super(kind: kind.to_s, key: key.to_s)
    end
  end

  Query = Data.define(:organization_key, :workspace_key, :text, :scope_filters, :limit) do
    def initialize(organization_key:, workspace_key:, text:, scope_filters:, limit:)
      raise ArgumentError, "organization key is required" if organization_key.to_s.blank?
      raise ArgumentError, "workspace key is invalid" unless workspace_key.to_s.match?(UUID_PATTERN)
      raise ArgumentError, "query text is required" if text.blank?
      raise ArgumentError, "limit must be between 1 and 50" unless limit in 1..50
      unless scope_filters.is_a?(Array) && scope_filters.any? && scope_filters.length <= 16 &&
          scope_filters.all? { |filter| filter.is_a?(ScopeFilter) }
        raise ArgumentError, "scope filters must contain between 1 and 16 scopes"
      end

      super
    end
  end

  Hit = Data.define(:memory_key, :score)
  IndexReceipt = Data.define(:document_id, :status)
  IndexStatus = Data.define(:status, :detail)

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

    def status(organization_key:, workspace_key:, memory_key:)
      raise NotImplementedError
    end

    def remove(organization_key:, workspace_key:, memory_key:)
      raise NotImplementedError
    end
  end
end
