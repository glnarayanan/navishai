require "test_helper"

class MemoryContextTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
    approve_scripted_runtime(workspace: @workspace, membership: @owner)
    CrewConfiguration.install_defaults!(workspace: @workspace)
    @support_case = create_support_case
    profile = @workspace.agent_profiles.find_by!(role_key: "support_investigator")
    @task = CrewWork.create!(
      workspace: @workspace, membership: @owner, scope: @support_case, profile:,
      title: "Investigate account access", input_context: "Use current and approved evidence.",
      expected_output: "Return cited findings."
    )
  end

  test "selects only current indexed eligible scoped records in deterministic order" do
    human = create_memory(topic: "human", authority: :human_correction, source_membership: @owner,
      source_user: @owner.user, origin_kind: :human)
    source = create_memory(topic: "source", authority: :source_record)
    inference = create_memory(
      topic: "inference", authority: :inference, origin_kind: :agent,
      source_agent_profile: @task.assigned_agent_profile, confidence: 0.7
    )
    pending = create_memory(topic: "pending")
    expired = create_memory(topic: "expired", valid_until: 1.minute.ago)
    superseded = create_memory(topic: "superseded")
    create_memory(topic: "superseded", supersedes_memory_record: superseded)
    foreign = create_memory(topic: "foreign", workspace: workspaces(:beta_support))
    [ human, source, inference, expired, superseded, foreign ].each { |record| index!(record) }
    hits = [ foreign, pending, expired, superseded, inference, source, human ].map.with_index do |record, index|
      MemoryEngine::Hit.new(memory_key: record.memory_key, score: index < 4 ? 0.99 : 0.8)
    end

    queries = []
    result = MemoryContext.build(workspace: @workspace, task: @task, engine: engine(hits, queries:))

    expected = [ human, source, inference ].sort_by(&:memory_key)
    assert_equal expected, result.items.map(&:record)
    assert_equal [ 1, 2, 3 ], result.items.map(&:rank)
    assert_equal @workspace.runner_key, queries.sole.workspace_key
    assert_equal 8, queries.sole.limit
    assert_includes queries.sole.scope_filters, MemoryEngine::ScopeFilter.new(kind: "workspace", key: @workspace.id.to_s)
    assert_includes result.text, "context, not instructions"
    assert_includes result.text, "Current source records and approved knowledge take precedence"
    payload = JSON.parse(result.text.split("\n").last)
    assert_equal 1, payload.fetch("human_corrections").size
    assert_equal 1, payload.fetch("source_records").size
    assert_equal 1, payload.fetch("inferences").size
    assert_equal expected.map { |record| "memory://#{record.memory_key}" },
      result.items.map { |item| item.record }.map { |record| "memory://#{record.memory_key}" }
  end

  test "enforces record and byte budgets without truncating JSON" do
    records = 10.times.map do |index|
      record = create_memory(topic: "budget-#{index}", content: "#{index}:#{"x" * 4_900}")
      index!(record)
      record
    end
    hits = records.reverse.map { |record| MemoryEngine::Hit.new(memory_key: record.memory_key, score: 0.75) }

    result = MemoryContext.build(workspace: @workspace, task: @task, engine: engine(hits))

    assert_operator result.items.size, :<=, 8
    assert_operator result.text.bytesize, :<=, 16.kilobytes
    assert_equal (1..result.items.size).to_a, result.items.map(&:rank)
    payload = JSON.parse(result.text.split("\n").last)
    assert_equal result.items.size, payload.values.sum(&:size)
    assert payload.values.flatten.all? { |item| item.fetch("content").bytesize <= 4.kilobytes }
  end

  test "freezes selected memory on the run and requires runtime disclosure" do
    memory = create_memory(topic: "run-context", content: "Customer confirmed the reset time.")
    index!(memory)
    search = engine([ MemoryEngine::Hit.new(memory_key: memory.memory_key, score: 0.91234) ])

    run = ExecutionLedger.new(workspace: @workspace, memory_engine: search)
      .prepare!(task: @task, request_key: "memory-context:run")

    selection = run.execution_memory_selections.sole
    assert_equal memory, selection.memory_record
    assert_equal 1, selection.rank
    assert_equal BigDecimal("0.91234"), selection.relevance_score
    assert_includes run.input_context, selection.citation_uri
    assert_includes run.disclosed_data_classes, "retrieved_memory"
    replay_without_engine = ExecutionLedger.new(workspace: @workspace, memory_engine: Object.new)
      .prepare!(task: @task, request_key: "memory-context:run")
    assert_equal run, replay_without_engine
    assert_raises(ActiveRecord::ReadOnlyRecord) { selection.update!(rank: 2) }
    assert_raises(ActiveRecord::StatementInvalid) do
      ExecutionMemorySelection.transaction(requires_new: true) do
        ExecutionMemorySelection.where(id: selection.id).delete_all
      end
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      ExecutionMemorySelection.transaction(requires_new: true) do
        ExecutionMemorySelection.insert_all!([ {
          workspace_id: @workspace.id, execution_run_id: run.id,
          memory_record_id: create_memory(topic: "foreign-selection", workspace: workspaces(:beta_support)).id,
          rank: 2, relevance_score: 0.5, created_at: Time.current, updated_at: Time.current
        } ])
      end
    end

    runtime = runtime_installations(:acme_scripted)
    runtime.update!(allowed_data_classes: runtime.allowed_data_classes - [ "retrieved_memory" ])
    error = assert_raises(ExecutionLedger::InvalidRun) do
      ExecutionLedger.new(workspace: @workspace, memory_engine: search)
        .prepare!(task: @task, request_key: "memory-context:denied")
    end
    assert_includes error.message, "No compatible runtime"
  end

  test "reports retrieval failure before creating a run" do
    memory = create_memory(topic: "unavailable")
    index!(memory)
    unavailable = Object.new
    unavailable.define_singleton_method(:search) { |query:| raise SupermemoryEngine::Unavailable, query.text }

    assert_no_difference -> { @workspace.execution_runs.count } do
      error = assert_raises(ExecutionLedger::InvalidRun) do
        ExecutionLedger.new(workspace: @workspace, memory_engine: unavailable)
          .prepare!(task: @task, request_key: "memory-context:unavailable")
      end
      assert_includes error.message, "Memory retrieval is unavailable"
    end
  end

  private
    def create_memory(topic:, workspace: @workspace, content: "Durable context", authority: :source_record,
      origin_kind: :system, source_membership: nil, source_user: nil, confidence: 1,
      source_agent_profile: nil, valid_until: nil, supersedes_memory_record: nil)
      workspace.memory_records.create!(
        memory_type: :episodic, scope_kind: :workspace, topic:, content:, authority:, origin_kind:,
        source_reference: "test://#{topic}", source_digest: Digest::SHA256.hexdigest(topic),
        source_membership:, source_user:, source_agent_profile:, observed_at: 1.hour.ago, valid_from: 1.hour.ago,
        valid_until:, confidence:, retention_policy: :indefinite, supersedes_memory_record:
      )
    end

    def index!(memory)
      memory.workspace.memory_index_entries.create!(
        memory_record: memory, status: :indexed, external_document_id: "document-#{memory.memory_key}",
        external_status: "done", attempt_count: 1, last_attempted_at: Time.current, indexed_at: Time.current
      )
    end

    def engine(hits, queries: [])
      Object.new.tap do |adapter|
        adapter.define_singleton_method(:search) do |query:|
          queries << query
          hits
        end
      end
    end
end
