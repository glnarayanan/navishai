require "test_helper"

class ReadPathPerformanceTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:acme_support)
    @membership = memberships(:owner_support)
    sign_in_as users(:owner)
  end

  test "case queue and detail keep record lookups bounded" do
    support_case = nil
    25.times do |index|
      account = @workspace.accounts.create!(name: "Queue account #{index}")
      contact = @workspace.contacts.create!(account:, name: "Queue contact #{index}")
      support_case = create_support_case(subject: "Queue case #{index}", contact:)
      add_inbound_message(support_case, body: "Queue message #{index}")
    end
    now = Time.current
    user_rows = 12.times.map do |index|
      {
        email_address: "read-path-author-#{index}@example.com",
        password_digest: users(:owner).password_digest,
        verified_at: now,
        created_at: now,
        updated_at: now
      }
    end
    user_ids = User.insert_all!(user_rows, returning: %w[id]).rows.flatten
    Membership.insert_all!(user_ids.map do |user_id|
      { workspace_id: @workspace.id, user_id:, role: "member", created_at: now, updated_at: now }
    end)
    ConversationMessage.insert_all!(user_ids.each_with_index.map do |user_id, index|
      {
        workspace_id: @workspace.id,
        conversation_id: support_case.conversation_id,
        direction: "outbound",
        author_kind: "user",
        author_user_id: user_id,
        body: "Author message #{index}",
        occurred_at: now + index.seconds,
        created_at: now,
        updated_at: now
      }
    end)

    queue_queries = capture_sql { get workspace_support_cases_path(@workspace) }
    assert_response :success
    assert_operator table_query_count(queue_queries, "contact_merges"), :<=, 1
    assert_operator table_query_count(queue_queries, "account_merges"), :<=, 1

    detail_queries = capture_sql { get workspace_support_case_path(@workspace, support_case) }
    assert_response :success
    assert_operator table_query_count(detail_queries, "users"), :<=, 6
  end

  test "memory library preloads case scope labels" do
    25.times do |index|
      support_case = create_support_case(subject: "Memory case #{index}")
      add_inbound_message(support_case, body: "Memory message #{index}")
    end

    queries = capture_sql { get workspace_memory_records_path(@workspace) }

    assert_response :success
    assert_operator table_query_count(queries, "support_cases"), :<=, 1
    assert_operator table_query_count(queries, "conversations"), :<=, 1
  end

  test "crew administration preloads published resolution contracts" do
    CrewConfiguration.install_defaults!(workspace: @workspace)
    ResolutionContractConfiguration.install_defaults!(workspace: @workspace)

    queries = capture_sql { get workspace_crew_templates_path(@workspace) }

    assert_response :success
    assert_operator table_query_count(queries, "resolution_contract_families"), :<=, 1
    assert_operator table_query_count(queries, "resolution_contract_versions"), :<=, 1
  end

  test "crew task proof preloads one contract version for all material claims" do
    approve_scripted_runtime(workspace: @workspace, membership: @membership)
    CrewConfiguration.install_defaults!(workspace: @workspace)
    contract = ResolutionContractConfiguration.install_defaults!(workspace: @workspace)
      .find_by!(family_key: "support_resolution").current_version
    support_case = create_support_case(subject: "Grounding query guard")
    profile = @workspace.agent_profiles.find_by!(role_key: "support_investigator")
    task = CrewWork.create!(
      workspace: @workspace, membership: @membership, scope: support_case, profile:,
      title: "Inspect proof", input_context: "Use current evidence.", expected_output: "Return grounded claims."
    )
    CrewWork.apply!(
      workspace: @workspace, membership: @membership, task:, command: :start,
      expected_sequence: task.current_event.sequence_number
    )
    run = ExecutionLedger.new(workspace: @workspace).prepare!(task:, request_key: "read-path:grounding")
    claims = 20.times.map do |index|
      {
        "key" => "claim_#{index}", "category" => "customer_account_fact", "text" => "Claim #{index}",
        "state" => "supported", "evidence" => [ {
          "kind" => "case", "locator" => "case://#{support_case.id}", "status" => "available",
          "observed_at" => support_case.status_changed_at.iso8601(6), "valid_until" => nil,
          "fresh_until" => 30.days.from_now.iso8601(6)
        } ]
      }
    end
    @workspace.crew_artifacts.create!(
      crew_task: task, execution_run: run, artifact_kind: "investigation", schema_version: 2,
      version_number: 1, body: "Grounded proof", uncertainty: "No uncertainty identified.",
      citations: [], conflicts: [], change_requests: [], payload_digest: Digest::SHA256.hexdigest("read-path-proof"),
      resolution_contract_version: contract, required_facts: claims.map { |claim| claim.fetch("key") },
      material_claims: claims, proposed_actions: [], policy_checks: [], contract_result_state: "complete",
      contract_blockers: [], contract_evaluated_at: Time.current
    )

    queries = capture_sql do
      get workspace_support_case_crew_task_path(@workspace, support_case, task)
    end

    assert_response :success
    assert_select ".run-artifact-facts li", count: 20
    assert_operator table_query_count(queries, "crew_artifacts"), :<=, 1
    assert_operator table_query_count(queries, "resolution_contract_versions"), :<=, 1
  end

  test "case and Account explanations bound detail while aggregating five thousand runs" do
    approve_scripted_runtime(workspace: @workspace, membership: @membership)
    CrewConfiguration.install_defaults!(workspace: @workspace)
    support_case = create_support_case(subject: "Large explanation ledger")
    account = support_case.conversation.contact.account
    profile = @workspace.agent_profiles.find_by!(role_key: "support_coordinator")
    task = CrewWork.create!(
      workspace: @workspace, membership: @membership, scope: support_case, profile:,
      title: "Large retained ledger", input_context: "Use retained facts.",
      expected_output: "Return a bounded result."
    )
    first = ExecutionLedger.new(workspace: @workspace).prepare!(
      task:, request_key: "read-path:large:1"
    )
    base = first.attributes.except("id")
    now = Time.current.change(usec: 0)
    (2..5_000).each_slice(500) do |attempts|
      ExecutionRun.insert_all!(attempts.map do |attempt|
        base.merge(
          "run_key" => SecureRandom.uuid, "request_key" => "read-path:large:#{attempt}",
          "attempt_number" => attempt, "created_at" => now - attempt.seconds,
          "updated_at" => now - attempt.seconds
        )
      end)
    end
    ingest_performance_event(first, 1, "run.admitted",
      workspace_key: @workspace.runner_key, task_key: task.task_key, attempt: 1)
    ingest_performance_event(first, 2, "run.started",
      adapter: "scripted", scenario: "large ledger", attempt: 1)
    ingest_performance_event(first, 3, "usage.observed", input_units: 321, output_units: 123)
    ingest_performance_event(first, 4, "run.failed", code: "large_fixture_failure", retryable: false)
    PublicWebSearch.insert_all!(75.times.map do |index|
      {
        workspace_id: @workspace.id, crew_task_id: task.id,
        request_key: "read-path:search:#{index}", query: "public status #{index}",
        provider_key: "searxng", status: "completed", policy_decision: "allowed",
        cost_units: 7, requested_by_membership_id: @membership.id,
        requested_by_user_id: @membership.user_id, retrieved_at: now - index.seconds,
        created_at: now - index.seconds, updated_at: now - index.seconds
      }
    end)

    case_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    case_queries = capture_sql do
      get workspace_outcome_explanation_path(
        @workspace, subject_type: "case", subject_id: support_case.id
      )
    end
    case_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - case_started

    assert_response :success
    assert_select ".explanation-lineage > li > ul > li", count: OutcomeExplanation::DETAIL_LIMITS.fetch(:runs)
    assert_select ".explanation-record-list > li", minimum: OutcomeExplanation::DETAIL_LIMITS.fetch(:searches)
    assert_select ".explanation-history-limit", text: /4,960 execution runs/
    assert_select ".explanation-history-limit", text: /25 public searches/
    assert_select ".explanation-usage", text: /321/
    assert_select ".explanation-usage", text: /123/
    assert_select ".explanation-usage", text: /525/
    assert_select ".explanation-usage", text: /625,000,000/
    assert_operator case_queries.size, :<=, 75
    assert_operator case_elapsed, :<, 5.seconds

    account_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    account_queries = capture_sql do
      get workspace_outcome_explanation_path(
        @workspace, subject_type: "account", subject_id: account.id
      )
    end
    account_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - account_started

    assert_response :success
    assert_select ".explanation-lineage > li > ul > li", count: OutcomeExplanation::DETAIL_LIMITS.fetch(:runs)
    assert_select ".explanation-history-limit", text: /4,960 execution runs/
    assert_select ".explanation-usage", text: /625,000,000/
    assert_operator account_queries.size, :<=, 80
    assert_operator account_elapsed, :<, 5.seconds
  end

  private
    def capture_sql
      queries = []
      subscriber = lambda do |_name, _started, _finished, _id, payload|
        queries << payload[:sql] unless payload[:name] == "SCHEMA" || payload[:cached]
      end
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { yield }
      queries
    end

    def table_query_count(queries, table)
      queries.count { |sql| sql.match?(/\bFROM "#{Regexp.escape(table)}"\b/) }
    end

    def ingest_performance_event(run, sequence, event_type, **data)
      event = ExecutionLedger.new(workspace: @workspace).ingest!(event: {
        "protocol_version" => "v1", "event_id" => SecureRandom.uuid, "run_id" => run.run_key,
        "sequence" => sequence, "event_type" => event_type,
        "occurred_at" => (Time.current.change(usec: 0) + sequence.seconds).iso8601(6),
        "data" => data.stringify_keys
      })
      connection = ActiveRecord::Base.connection
      connection.execute("SET CONSTRAINTS ALL IMMEDIATE")
      connection.execute("SET CONSTRAINTS ALL DEFERRED")
      event
    end
end
