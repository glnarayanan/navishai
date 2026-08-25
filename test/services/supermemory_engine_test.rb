require "test_helper"

class SupermemoryEngineTest < ActiveSupport::TestCase
  setup do
    @engine = SupermemoryEngine.new(api_key: "sm_#{"a" * 32}")
    @document = MemoryEngine::Document.new(
      organization_key: "10",
      workspace_key: "3d9c74df-cba1-4470-947f-bec918791065",
      memory_key: "6eb62dc0-2c6c-42fb-841b-4ddd099f31c5",
      memory_type: "semantic",
      scope_kind: "account",
      scope_key: "20",
      content: "Acme has premium support",
      source_reference: "account://20",
      observed_at: Time.current,
      valid_from: Time.current,
      valid_until: nil,
      confidence: 1.0
    )
    @scope = MemoryEngine::ScopeFilter.new(kind: "account", key: "20")
    @query = MemoryEngine::Query.new(
      organization_key: @document.organization_key,
      workspace_key: @document.workspace_key,
      text: "premium support",
      scope_filters: [ @scope ],
      limit: 5
    )
  end

  test "rejects managed, cleartext remote, and invalid-key configuration" do
    assert_raises(SupermemoryEngine::ConfigurationError) do
      SupermemoryEngine.new(address: "https://api.supermemory.ai", api_key: "sm_#{"a" * 32}")
    end
    assert_raises(SupermemoryEngine::ConfigurationError) do
      SupermemoryEngine.new(address: "http://memory.internal:6767", api_key: "sm_#{"a" * 32}")
    end
    assert_raises(SupermemoryEngine::ConfigurationError) do
      SupermemoryEngine.new(api_key: "short")
    end
    assert_raises(SupermemoryEngine::ConfigurationError) do
      SupermemoryEngine.new(address: "https://other.supermemory.ai.", api_key: "sm_#{"a" * 32}")
    end
  end

  test "rejects index operations without authoritative tenant identity" do
    invalid = MemoryEngine::Document.new(**@document.to_h.merge(workspace_key: ""))

    assert_raises(SupermemoryEngine::ConfigurationError) { @engine.index(document: invalid) }
  end

  test "indexes with an idempotent custom id and redundant tenant binding" do
    captured = stub_responses(
      response(202, id: "supermemory-document", status: "queued")
    )

    receipt = @engine.index(document: @document)

    request = captured.sole
    payload = JSON.parse(request.body)
    assert_equal "/v3/documents", request.path
    assert_equal "Bearer sm_#{"a" * 32}", request["Authorization"]
    assert_equal @document.memory_key, payload.fetch("customId")
    assert_equal @document.workspace_key, payload.fetch("containerTag")
    assert_equal "superrag", payload.fetch("taskType")
    assert_equal @document.organization_key, payload.dig("metadata", "navishai_organization_key")
    assert_equal @document.workspace_key, payload.dig("metadata", "navishai_workspace_key")
    assert_equal @document.memory_key, payload.dig("metadata", "navishai_memory_key")
    assert_equal "queued", receipt.status
  end

  test "search binds container and metadata filters and accepts only requested scope hits" do
    lower_duplicate = search_result
    lower_duplicate["similarity"] = 0.5
    captured = stub_responses(response(200, results: [ lower_duplicate, search_result ]))

    hits = @engine.search(query: @query)

    payload = JSON.parse(captured.sole.body)
    assert_equal "/v4/search", captured.sole.path
    assert_equal @document.workspace_key, payload.fetch("containerTag")
    assert_equal "documents", payload.fetch("searchMode")
    assert_includes payload.dig("filters", "AND"),
      { "key" => "navishai_organization_key", "value" => @document.organization_key }
    assert_includes payload.dig("filters", "AND"),
      { "key" => "navishai_workspace_key", "value" => @document.workspace_key }
    assert_equal @document.memory_key, hits.sole.memory_key
    assert_equal 0.87, hits.sole.score
  end

  test "search fails closed when the engine returns another tenant or scope" do
    foreign_tenant = search_result
    foreign_tenant["metadata"]["navishai_workspace_key"] = "other-workspace"
    stub_responses(response(200, results: [ foreign_tenant ]))
    assert_raises(SupermemoryEngine::TenantMismatch) { @engine.search(query: @query) }

    foreign_scope = search_result
    foreign_scope["metadata"]["scope_key"] = "999"
    stub_responses(response(200, results: [ foreign_scope ]))
    assert_raises(SupermemoryEngine::TenantMismatch) { @engine.search(query: @query) }
  end

  test "status and deletion verify the document tenant before acting" do
    captured = stub_responses(
      response(200, document_payload(status: "done")),
      response(200, document_payload),
      response(204, nil)
    )

    status = @engine.status(
      organization_key: @document.organization_key,
      workspace_key: @document.workspace_key,
      memory_key: @document.memory_key
    )
    removed = @engine.remove(
      organization_key: @document.organization_key,
      workspace_key: @document.workspace_key,
      memory_key: @document.memory_key
    )

    assert_equal "done", status.status
    assert removed
    assert_equal [ "GET", "GET", "DELETE" ], captured.map(&:method)

    captured = stub_responses(response(200, document_payload(workspace_key: "other-workspace")))
    assert_raises(SupermemoryEngine::TenantMismatch) do
      @engine.remove(
        organization_key: @document.organization_key,
        workspace_key: @document.workspace_key,
        memory_key: @document.memory_key
      )
    end
    assert_equal 1, captured.length
  end

  test "deletion sends the delete only after a matching lookup" do
    captured = stub_responses(
      response(200, document_payload),
      response(204, nil)
    )

    assert @engine.remove(
      organization_key: @document.organization_key,
      workspace_key: @document.workspace_key,
      memory_key: @document.memory_key
    )
    assert_equal [ "GET", "DELETE" ], captured.map(&:method)
    assert_equal captured.first.path, captured.second.path
  end

  test "health reports failures without leaking request details" do
    stub_responses(response(200, processing: []))
    assert @engine.health.available?

    @engine.define_singleton_method(:perform) { |_request| raise Errno::ECONNREFUSED }
    health = @engine.health
    assert_not health.available?
    assert_equal "ECONNREFUSED", health.detail
  end

  private
    def response(code, payload)
      SupermemoryEngine::Response.new(code:, body: payload.nil? ? "" : JSON.generate(payload))
    end

    def stub_responses(*responses)
      captured = []
      queue = responses.dup
      @engine.define_singleton_method(:perform) do |request|
        captured << request
        queue.shift || raise("unexpected request")
      end
      captured
    end

    def document_payload(status: "done", workspace_key: @document.workspace_key)
      {
        "status" => status,
        "metadata" => {
          "navishai_organization_key" => @document.organization_key,
          "navishai_workspace_key" => workspace_key,
          "navishai_memory_key" => @document.memory_key
        }
      }
    end

    def search_result
      {
        "similarity" => 0.87,
        "metadata" => document_payload.fetch("metadata").merge(
          "scope_kind" => @document.scope_kind,
          "scope_key" => @document.scope_key
        )
      }
    end
end
