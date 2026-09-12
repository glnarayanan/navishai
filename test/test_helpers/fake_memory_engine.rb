class FakeMemoryEngine < MemoryEngine::Adapter
  attr_accessor :index_status, :unavailable, :auth_error, :search_miss, :leak_to_foreign,
    :remove_fails, :status_done_after

  def initialize
    @documents = {}
    @index_status = "done"
    @status_calls = Hash.new(0)
    @unavailable = false
    @auth_error = false
    @search_miss = false
    @leak_to_foreign = false
    @remove_fails = false
    @status_done_after = nil
  end

  def health
    raise_if_broken!
    MemoryEngine::Health.new(available: true, detail: "ready")
  rescue SupermemoryEngine::Unavailable
    MemoryEngine::Health.new(available: false, detail: "Unavailable")
  end

  def index(document:)
    raise_if_broken!
    @documents[document.memory_key] = document
    MemoryEngine::IndexReceipt.new(document_id: document.memory_key, status: @index_status)
  end

  def search(query:)
    raise_if_broken!
    @documents.values.filter_map do |document|
      next unless include_in_search?(document, query)

      MemoryEngine::Hit.new(memory_key: document.memory_key, score: 0.91)
    end
  end

  def status(organization_key:, workspace_key:, memory_key:)
    raise_if_broken!
    document = @documents[memory_key]
    raise SupermemoryEngine::Unavailable, "missing" unless document

    @status_calls[memory_key] += 1
    current = if @status_done_after && @status_calls[memory_key] > @status_done_after
      "done"
    else
      @index_status
    end
    MemoryEngine::IndexStatus.new(status: current, detail: nil)
  end

  def remove(organization_key:, workspace_key:, memory_key:)
    raise_if_broken!
    return false if @remove_fails

    @documents.delete(memory_key)
    true
  end

  private
    def raise_if_broken!
      raise SupermemoryEngine::AuthenticationError, "rejected" if @auth_error
      raise SupermemoryEngine::Unavailable, "offline" if @unavailable
    end

    def include_in_search?(document, query)
      token_match = document.content.include?(query.text)
      return false unless token_match
      return false if @search_miss && document.workspace_key == query.workspace_key
      return true if @leak_to_foreign && document.workspace_key != query.workspace_key

      document.workspace_key == query.workspace_key &&
        document.organization_key == query.organization_key &&
        query.scope_filters.any? { |scope| scope.kind == document.scope_kind && scope.key == document.scope_key }
    end
end
