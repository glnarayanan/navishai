require "test_helper"

class UsageCostCaptureTest < ActiveSupport::TestCase
  BIGINT_MAX = 9_223_372_036_854_775_807

  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
    approve_scripted_runtime(workspace: @workspace, membership: @owner)
    CrewConfiguration.install_defaults!(workspace: @workspace)
    @support_case = create_support_case(subject: "Usage provenance")
    @coordinator = @workspace.agent_profiles.find_by!(role_key: "support_coordinator")
    @task = create_task(@coordinator, "Measure one outcome")
    @clock = Time.current.change(usec: 0)
  end

  test "freezes a configured estimate and preserves it through later rates and retention" do
    first_rate = publish_rate(input_rate: "2", output_rate: "4", search_rate: "5")
    run = prepare_run("cost:configured")
    assert_equal first_rate, run.usage_rate_version

    finish_run(run, usage: [ { input_units: 10_000, output_units: 5_000 } ])
    snapshot = run.reload.usage_cost_snapshot

    assert snapshot.complete?
    assert snapshot.configured_rate?
    assert_equal "USD", snapshot.currency
    assert_equal 40_000, snapshot.amount_micros
    assert_equal 10_000, snapshot.observed_input_units
    assert_equal 5_000, snapshot.observed_output_units
    assert_equal first_rate, snapshot.applied_usage_rate_version
    assert_equal first_rate.version_number, snapshot.calculation_provenance.fetch("rate_version")
    assert_equal "bounded test rate", snapshot.calculation_provenance.fetch("source")

    second_rate = publish_rate(
      input_rate: "20", output_rate: "40", search_rate: "50",
      expected_current_version_id: first_rate.id
    )
    UsageRateConfiguration.rollback!(
      workspace: @workspace, membership: @owner, version: first_rate,
      expected_current_version_id: second_rate.id
    )
    frozen = snapshot.attributes

    expire_workspace_content(@workspace, 1.day.from_now)

    assert_equal frozen, snapshot.reload.attributes
    assert_equal first_rate, run.reload.usage_rate_version
    assert_raises(ActiveRecord::ReadOnlyRecord) { snapshot.update!(amount_micros: 1) }
    assert_raises(ActiveRecord::StatementInvalid) do
      UsageCostSnapshot.transaction(requires_new: true) do
        UsageCostSnapshot.where(id: snapshot.id).update_all(amount_micros: 1)
      end
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      ExecutionRun.transaction(requires_new: true) do
        ExecutionRun.where(id: run.id).update_all(usage_rate_version_id: second_rate.id)
      end
    end
  end

  test "adapter amounts override configured estimates and require one currency" do
    publish_rate(input_rate: "99", output_rate: "99", search_rate: "99")
    run = prepare_run("cost:adapter")
    start_run(run)
    ingest(run, 3, "usage.observed",
      input_units: 10, output_units: 4, amount_micros: 120_000, currency: "USD")

    assert_raises(ExecutionLedger::EventConflict) do
      ingest(run, 4, "usage.observed",
        input_units: 5, output_units: 2, amount_micros: 80_000, currency: "EUR")
    end
    assert_equal 3, run.reload.current_sequence

    ingest(run, 4, "usage.observed",
      input_units: 5, output_units: 2, amount_micros: 80_000, currency: "USD")
    ingest(run, 5, "run.failed", code: "scripted_failure", retryable: false)
    snapshot = run.reload.usage_cost_snapshot

    assert snapshot.complete?
    assert snapshot.adapter_reported?
    assert_equal 200_000, snapshot.amount_micros
    assert_equal "scripted", snapshot.calculation_provenance.fetch("adapter_key")
    assert_equal 2, snapshot.calculation_provenance.fetch("reported_amount_event_count")
  end

  test "keeps terminal runs when adapter amounts sum beyond bigint" do
    exact_run = prepare_run("cost:adapter-max")
    finish_run(exact_run, usage: [
      { input_units: 0, output_units: 0, amount_micros: BIGINT_MAX - 1, currency: "USD" },
      { input_units: 0, output_units: 0, amount_micros: 1, currency: "USD" }
    ])
    exact = exact_run.reload.usage_cost_snapshot
    assert exact_run.reload.failed?
    assert exact.complete?
    assert_equal BIGINT_MAX, exact.amount_micros

    overflow_run = prepare_run("cost:adapter-overflow")
    finish_run(overflow_run, usage: [
      { input_units: 7, output_units: 3, amount_micros: BIGINT_MAX, currency: "USD" },
      { input_units: 2, output_units: 1, amount_micros: 1, currency: "USD" }
    ])
    overflow = overflow_run.reload.usage_cost_snapshot

    assert overflow_run.reload.failed?
    assert overflow.unavailable?
    assert_nil overflow.source
    assert_nil overflow.currency
    assert_nil overflow.amount_micros
    assert_equal 9, overflow.observed_input_units
    assert_equal 4, overflow.observed_output_units
    assert_equal "reported_amount_out_of_range", overflow.calculation_provenance.fetch("reason")
  end

  test "records unavailable partial and not reported money without converting unknown to zero" do
    unavailable_run = prepare_run("cost:unavailable")
    finish_run(unavailable_run, usage: [ { input_units: 10, output_units: 2 } ])
    unavailable = unavailable_run.reload.usage_cost_snapshot
    assert unavailable.unavailable?
    assert_nil unavailable.amount_micros
    assert_equal "no_rate_frozen", unavailable.calculation_provenance.fetch("reason")

    rate = publish_rate(input_rate: "2", output_rate: "", search_rate: "")
    partial_run = prepare_run("cost:partial")
    assert_equal rate, partial_run.usage_rate_version
    finish_run(partial_run, usage: [ { input_units: 10, output_units: 2 } ])
    partial = partial_run.reload.usage_cost_snapshot
    assert partial.partial?
    assert_equal 20, partial.amount_micros
    assert_equal [ "output" ], partial.calculation_provenance.fetch("missing_components")

    unknown_run = prepare_run("cost:not-reported")
    finish_run(unknown_run)
    not_reported = unknown_run.reload.usage_cost_snapshot
    assert not_reported.not_reported?
    assert_nil not_reported.amount_micros
    assert_nil not_reported.currency
    assert_equal "usage_not_reported", not_reported.calculation_provenance.fetch("reason")
  end

  test "search estimates reconcile to cost units and failures stay not reported" do
    rate = publish_rate(input_rate: "", output_rate: "", search_rate: "5")
    investigator = @workspace.agent_profiles.find_by!(role_key: "support_investigator")
    task = create_task(investigator, "Search public evidence")
    response = {
      "protocol_version" => "v1", "workspace_key" => @workspace.runner_key,
      "request_key" => "cost:search", "query" => "status history",
      "provider_key" => "searxng", "policy_decision" => "allowed", "cost_units" => 100_000,
      "retrieved_at" => @clock.iso8601,
      "results" => []
    }
    client = Object.new
    client.define_singleton_method(:web_search_catalog!) { |**| { "default_provider_key" => "searxng", "provider_keys" => [ "searxng" ] } }
    client.define_singleton_method(:web_search!) { |**| response }

    search = PublicWebResearch.perform!(
      workspace: @workspace, membership: @owner, task:, query: "status history",
      request_key: "cost:search", client:
    )
    snapshot = search.usage_cost_snapshot
    assert_equal rate, search.usage_rate_version
    assert snapshot.complete?
    assert snapshot.configured_rate?
    assert_equal 100_000, snapshot.observed_search_units
    assert_equal 500_000, snapshot.amount_micros

    failure = Object.new
    failure.define_singleton_method(:web_search_catalog!) { |**| { "default_provider_key" => "searxng", "provider_keys" => [ "searxng" ] } }
    failure.define_singleton_method(:web_search!) { |**| raise RunnerClient::Unavailable, "offline" }
    assert_raises(RunnerClient::Unavailable) do
      PublicWebResearch.perform!(
        workspace: @workspace, membership: @owner, task:, query: "status failure",
        request_key: "cost:search-failed", client: failure
      )
    end
    failed = @workspace.public_web_searches.find_by!(request_key: "cost:search-failed")
    assert failed.usage_cost_snapshot.not_reported?
    assert_nil failed.usage_cost_snapshot.amount_micros
  end

  test "keeps a completed search when its configured calculation exceeds bigint" do
    publish_rate(input_rate: "", output_rate: "", search_rate: "1000000")
    investigator = @workspace.agent_profiles.find_by!(role_key: "support_investigator")
    task = create_task(investigator, "Search at the numeric boundary")
    response = {
      "protocol_version" => "v1", "workspace_key" => @workspace.runner_key,
      "request_key" => "cost:search-overflow", "query" => "status history",
      "provider_key" => "searxng", "policy_decision" => "allowed", "cost_units" => BIGINT_MAX,
      "retrieved_at" => @clock.iso8601, "results" => []
    }
    client = Object.new
    client.define_singleton_method(:web_search_catalog!) { |**| { "default_provider_key" => "searxng", "provider_keys" => [ "searxng" ] } }
    client.define_singleton_method(:web_search!) { |**| response }

    search = PublicWebResearch.perform!(
      workspace: @workspace, membership: @owner, task:, query: "status history",
      request_key: "cost:search-overflow", client:
    )
    snapshot = search.reload.usage_cost_snapshot

    assert search.completed?
    assert snapshot.unavailable?
    assert_nil snapshot.source
    assert_nil snapshot.currency
    assert_nil snapshot.amount_micros
    assert_equal BIGINT_MAX, snapshot.observed_search_units
    assert_equal "calculated_amount_out_of_range", snapshot.calculation_provenance.fetch("reason")
  end

  test "models accept bigint max and reject max plus one" do
    search = @workspace.public_web_searches.new(
      crew_task: @task, request_key: "cost:model-bound", query: "model boundary",
      requested_by_membership: @owner, requested_by_user: @owner.user, cost_units: BIGINT_MAX
    )
    assert search.valid?
    search.cost_units = BIGINT_MAX + 1
    refute search.valid?
    assert search.errors.of_kind?(:cost_units, :less_than_or_equal_to)

    run = prepare_run("cost:snapshot-model-bound")
    numeric_fields = %i[amount_micros observed_input_units observed_output_units observed_search_units]
    numeric_fields.each do |field|
      snapshot = @workspace.usage_cost_snapshots.new(
        execution_run: run, status: "complete", source: "adapter_reported", currency: "USD",
        amount_micros: BIGINT_MAX, captured_at: @clock
      )
      snapshot.public_send("#{field}=", BIGINT_MAX)
      assert snapshot.valid?, "expected #{field} at bigint max to be valid"

      snapshot.public_send("#{field}=", BIGINT_MAX + 1)
      refute snapshot.valid?, "expected #{field} above bigint max to be invalid"
      assert snapshot.errors.of_kind?(field, :less_than_or_equal_to)
    end
  end

  private
    def create_task(profile, title)
      CrewWork.create!(
        workspace: @workspace, membership: @owner, scope: @support_case, profile:, title:,
        input_context: "Use retained evidence only.", expected_output: "Return a bounded result."
      )
    end

    def publish_rate(input_rate:, output_rate:, search_rate:, expected_current_version_id: nil)
      UsageRateConfiguration.publish!(
        workspace: @workspace, membership: @owner,
        attributes: {
          expected_current_version_id:, currency: "USD", source_name: "bounded test rate",
          input_rate:, output_rate:, search_rate:
        }
      )
    end

    def prepare_run(request_key)
      ExecutionLedger.new(workspace: @workspace).prepare!(task: @task, request_key:)
    end

    def start_run(run)
      ingest(run, 1, "run.admitted",
        workspace_key: @workspace.runner_key, task_key: run.crew_task.task_key, attempt: run.attempt_number)
      ingest(run, 2, "run.started", adapter: "scripted", scenario: "usage test", attempt: run.attempt_number)
    end

    def finish_run(run, usage: [])
      start_run(run)
      usage.each_with_index do |data, index|
        ingest(run, index + 3, "usage.observed", **data)
      end
      ingest(run, usage.size + 3, "run.failed", code: "scripted_failure", retryable: false)
    end

    def ingest(run, sequence, event_type, **data)
      event = ExecutionLedger.new(workspace: @workspace).ingest!(event: {
        "protocol_version" => "v1", "event_id" => SecureRandom.uuid, "run_id" => run.run_key,
        "sequence" => sequence, "event_type" => event_type,
        "occurred_at" => (@clock + sequence.seconds).iso8601(6), "data" => data.stringify_keys
      })
      connection = ActiveRecord::Base.connection
      connection.execute("SET CONSTRAINTS ALL IMMEDIATE")
      connection.execute("SET CONSTRAINTS ALL DEFERRED")
      event
    end

    def expire_workspace_content(workspace, cutoff)
      connection = ActiveRecord::Base.connection
      connection.execute("SET CONSTRAINTS ALL IMMEDIATE")
      connection.select_value(
        "SELECT expire_workspace_content(#{workspace.id}, #{connection.quote(cutoff)})"
      )
    ensure
      connection&.execute("SET CONSTRAINTS ALL DEFERRED")
    end
end
