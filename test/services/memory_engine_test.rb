require "test_helper"

class MemoryEngineTest < ActiveSupport::TestCase
  test "builds a provider-neutral index document with a tenant key" do
    workspace = workspaces(:acme_support)
    now = Time.current
    memory = MemoryRecord.create!(
      workspace: workspace,
      memory_type: "semantic",
      scope_kind: "workspace",
      topic: "service-tier",
      content: "The account has premium support",
      authority: "source_record",
      origin_kind: "system",
      source_reference: "account://#{accounts(:acme).id}",
      source_digest: Digest::SHA256.hexdigest("account-source"),
      observed_at: now,
      valid_from: now,
      confidence: 1,
      retention_policy: "source_lifetime"
    )

    document = MemoryEngine::Document.from(memory)

    assert_equal workspace.runner_key, document.workspace_key
    assert_equal memory.memory_key, document.memory_key
    assert_equal "workspace", document.scope_kind
    assert_equal workspace.id.to_s, document.scope_key
    assert_equal memory.content, document.content
    assert_raises(ArgumentError) do
      MemoryEngine::Query.new(workspace_key: workspace.runner_key, text: "", scope_filters: [], limit: 10)
    end
    assert_raises(ArgumentError) do
      MemoryEngine::Query.new(workspace_key: workspace.runner_key, text: "support", scope_filters: [], limit: 51)
    end
  end
end
