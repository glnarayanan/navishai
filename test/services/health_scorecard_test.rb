require "test_helper"

class HealthScorecardTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
    @scorecard = HealthScorecardDesigner.install_default!(workspace: @workspace)
    @account = @workspace.accounts.create!(name: "Scorecard Test")
    @at = Time.zone.parse("2026-08-24 12:00:00")
    AccountHealth.recalculate!(workspace: @workspace, account: @account,
      trigger_kind: "human_request", membership: @owner, at: @at)
  end

  test "maps a guided proposal to deterministic bounded rules" do
    version = propose(weights: { "open_cases" => 40, "customer_inactivity_days" => 10 })

    assert_equal 2, version.version_number
    assert_equal %w[open_cases customer_inactivity_days], version.definition.fetch("rules").pluck("signal_key")
    assert_equal 1, version.design_turns.count
    assert_match "2 deterministic signals", version.explanation
    assert_equal @owner.user, version.created_by_user
    assert AuditEvent.exists?(action: "scorecard.proposed", subject_type: version.class.name,
      subject_id: version.id, actor: @owner.user)

    assert_raises(HealthScorecardDesigner::InvalidProposal) do
      propose(healthy_min: 40, watch_min: 50, weights: { "open_cases" => 20 })
    end
  end

  test "keeps new support evidence disabled until a human proposes previews and an Admin publishes it" do
    original = @scorecard.current_version
    assert_empty original.definition.fetch("rules").pluck("signal_key") & %w[
      recurring_issue_tags_90d reopened_cases_90d resolutions_without_proof_90d
    ]
    version = propose(weights: { "recurring_issue_tags_90d" => 15, "reopened_cases_90d" => 20 })

    assert_equal %w[recurring_issue_tags_90d reopened_cases_90d], version.definition.fetch("rules").pluck("signal_key")
    assert_equal original, @scorecard.reload.current_version
    HealthScorecardBacktester.run!(workspace: @workspace, membership: @owner, version:, at: @at)
    publish_version(version, expected_current_version_id: original.id)
    assert_equal version, @scorecard.reload.current_version
  end

  test "retains a replayable preview and requires it before publish" do
    version = propose(weights: { "open_cases" => 40 })

    assert_raises(HealthScorecardPublisher::InvalidPublish) do
      HealthScorecardPublisher.publish!(workspace: @workspace, membership: @owner, version:,
        expected_current_version_id: @scorecard.current_version_id, expected_backtest_id: nil)
    end
    first = HealthScorecardBacktester.run!(workspace: @workspace, membership: @owner, version:, at: @at + 1.hour)
    second = HealthScorecardBacktester.run!(workspace: @workspace, membership: @owner, version:, at: @at + 2.hours)

    assert_equal 1, first.sample_count
    assert_equal first.source_digest, second.source_digest
    assert_equal first.results, second.results
    assert_equal @account.id, first.results.fetch("current").find { |row| row.fetch("account_id") == @account.id }.fetch("account_id")
    assert_equal HealthScorecardBacktester::MAX_SNAPSHOTS, second.results.fetch("summary").fetch("snapshot_limit")
    assert_equal false, second.results.fetch("summary").fetch("truncated")
    assert_raises(HealthScorecardPublisher::InvalidPublish) do
      HealthScorecardPublisher.publish!(workspace: @workspace, membership: @owner, version:,
        expected_current_version_id: @scorecard.current_version_id, expected_backtest_id: first.id)
    end
    assert_equal version, publish_version(version)
    assert_equal version, @scorecard.reload.current_version
  end

  test "selects current assessments for sampled accounts in one query with stable tie breaking" do
    newer = AccountHealth.recalculate!(workspace: @workspace, account: @account,
      trigger_kind: "schedule", membership: @owner, at: @at)
    version = propose(weights: { "open_cases" => 40 })
    queries = []
    subscriber = ->(*args) { queries << args.last.fetch(:sql) }

    backtest = ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      HealthScorecardBacktester.run!(workspace: @workspace, membership: @owner, version:, at: @at + 1.hour)
    end

    assert_equal [ newer.id ], backtest.results.fetch("current")
      .select { |row| row.fetch("account_id") == @account.id }.pluck("assessment_id")
    current_queries = queries.grep(/DISTINCT ON \(account_health_assessments\.account_id\)/)
    assert_equal 1, current_queries.size
    assert_match(/ORDER BY .*account_id.*ASC, .*calculated_at.*DESC, .*id.*DESC/, current_queries.sole)
  end

  test "keeps every current account in the preview when one account fills the historical replay cap" do
    crowded = @workspace.accounts.create!(name: "Crowded history")
    quiet = @workspace.accounts.create!(name: "Quiet current")
    quiet_assessment = create_backtest_assessment(quiet, calculated_at: @at - 1.day)
    HealthScorecardBacktester::MAX_SNAPSHOTS.times do |offset|
      create_backtest_assessment(crowded, calculated_at: @at + offset.seconds)
    end
    version = propose(weights: { "open_cases" => 40 })

    backtest = HealthScorecardBacktester.run!(workspace: @workspace, membership: @owner, version:, at: @at + 1.hour)

    assert_equal [ quiet_assessment.id ], backtest.results.fetch("current")
      .select { |row| row.fetch("account_id") == quiet.id }.pluck("assessment_id")
    summary = backtest.results.fetch("summary")
    assert_equal @workspace.accounts.count, summary.fetch("current_account_count")
    assert_equal HealthScorecardBacktester::MAX_SNAPSHOTS, summary.fetch("historical_snapshot_count")
    assert_operator summary.fetch("historical_snapshot_omitted_count"), :>, 0
    assert_equal "most_recent_by_calculated_at_then_id", summary.fetch("historical_sampling_rule")
    assert summary.fetch("historical_starts_at").present?
    assert summary.fetch("historical_ends_at").present?
  end

  test "bounds persisted current detail without excluding current accounts from coverage or freshness" do
    accounts = @workspace.accounts.order(:id).to_a
    accounts.concat(Array.new(150 - accounts.size) { |index| @workspace.accounts.create!(name: "Current detail #{index}") })
    accounts.reject { |account| account == @account }.each do |account|
      create_backtest_assessment(account, calculated_at: @at - 1.day)
    end
    HealthScorecardBacktester::MAX_SNAPSHOTS.times do |offset|
      create_backtest_assessment(@account, calculated_at: @at + offset.seconds)
    end
    version = propose(weights: HealthScorecardDefinition::CATALOG.keys.to_h { |key| [ key, 25 ] })

    backtest = HealthScorecardBacktester.run!(workspace: @workspace, membership: @owner, version:, at: @at + 1.hour)

    summary = backtest.results.fetch("summary")
    assert_equal accounts.size, summary.fetch("current_account_count")
    assert_equal HealthScorecardBacktester::MAX_CURRENT_DETAILS, summary.fetch("current_detail_count")
    assert_equal 50, summary.fetch("current_detail_omitted_count")
    assert_equal "lowest_account_id_first", summary.fetch("current_sampling_rule")
    assert_equal accounts.sort_by(&:id).first(HealthScorecardBacktester::MAX_CURRENT_DETAILS).pluck(:id),
      backtest.results.fetch("current").pluck("account_id")
    assert_equal HealthScorecardBacktester::MAX_SNAPSHOTS, backtest.results.fetch("history").size
    assert_operator backtest.results.to_json.bytesize, :<=, 1.megabyte

    omitted_account = accounts.sort_by(&:id).last
    digest = backtest.source_digest
    create_backtest_assessment(omitted_account, calculated_at: @at + 2.hours)
    refute_equal digest, HealthScorecardBacktester.source_digest_for(workspace: @workspace, version:)
  end

  test "retains no-data incomplete and no-change comparison states with signal reasons" do
    no_data = @workspace.accounts.create!(name: "No retained health")
    incomplete = @workspace.accounts.create!(name: "Missing renewal input")
    changed = @workspace.accounts.create!(name: "Changed by open cases")
    unchanged = @workspace.accounts.create!(name: "No score change")
    create_backtest_assessment(incomplete, calculated_at: @at)
    changed_assessment = create_backtest_assessment(changed, calculated_at: @at, open_cases: 2)
    changed_assessment.signals.create!(
      workspace: @workspace, signal_key: "renewal_on", value_kind: "date", date_value: @at.to_date + 365,
      weight: 0, risk_points: 0, source_kind: "account_input", source_locator: "account://#{changed.id}/renewal",
      range_ends_at: @at
    )
    unchanged_assessment = create_backtest_assessment(unchanged, calculated_at: @at)
    unchanged_assessment.signals.create!(
      workspace: @workspace, signal_key: "renewal_on", value_kind: "date", date_value: @at.to_date + 365,
      weight: 0, risk_points: 0, source_kind: "account_input", source_locator: "account://#{unchanged.id}/renewal",
      range_ends_at: @at
    )
    version = propose(weights: { "open_cases" => 20, "renewal_on" => 25 })

    backtest = HealthScorecardBacktester.run!(workspace: @workspace, membership: @owner, version:, at: @at + 1.hour)
    rows = backtest.results.fetch("current").index_by { |row| row.fetch("account_id") }

    assert_equal "no_data", rows.fetch(no_data.id).fetch("comparison_status")
    assert_equal "incomparable", rows.fetch(incomplete.id).fetch("comparison_status")
    assert_equal [ "renewal_on" ], rows.fetch(incomplete.id).fetch("missing_signal_keys")
    assert_equal "changed", rows.fetch(changed.id).fetch("comparison_status")
    assert_equal "no_change", rows.fetch(unchanged.id).fetch("comparison_status")
    reason = rows.fetch(changed.id).fetch("signal_reasons").find { |entry| entry.fetch("signal_key") == "open_cases" }
    assert_equal "compared", reason.fetch("status")
    assert_match(/changes risk points from 0 to 10/, reason.fetch("reason"))
    assert_equal @workspace.accounts.where.missing(:health_assessments).count,
      backtest.results.fetch("summary").fetch("no_data_count")
    assert_operator backtest.results.fetch("summary").fetch("no_change_count"), :>=, 1
    assert_operator backtest.results.fetch("summary").fetch("incomparable_count"), :>=, 1
  end

  test "rolls back a backtest when its audit fails and rejects a stale publish" do
    version = propose(weights: { "open_cases" => 30 })
    before = HealthScorecardBacktest.count
    original_record = AuditEvent.method(:record!)
    AuditEvent.define_singleton_method(:record!) { |**| raise "audit unavailable" }
    begin
      assert_raises(RuntimeError) do
        HealthScorecardBacktester.run!(workspace: @workspace, membership: @owner, version:, at: @at)
      end
    ensure
      AuditEvent.define_singleton_method(:record!, original_record)
    end
    assert_equal before, HealthScorecardBacktest.count

    HealthScorecardBacktester.run!(workspace: @workspace, membership: @owner, version:, at: @at)
    original_id = @scorecard.current_version_id
    publish_version(version, expected_current_version_id: original_id)
    newer = propose(weights: { "open_cases" => 50 })
    HealthScorecardBacktester.run!(workspace: @workspace, membership: @owner, version: newer, at: @at)
    assert_raises(HealthScorecardPublisher::InvalidPublish) do
      publish_version(newer, expected_current_version_id: original_id)
    end
    assert_equal version, @scorecard.reload.current_version
  end

  test "rolls future deterministic scoring back without rewriting retained assessments" do
    original = @scorecard.current_version
    HealthScorecardBacktester.run!(workspace: @workspace, membership: @owner, version: original, at: @at)
    version = propose(weights: { "open_cases" => 100 })
    HealthScorecardBacktester.run!(workspace: @workspace, membership: @owner, version:, at: @at)
    publish_version(version, expected_current_version_id: original.id)
    prior_ids = @account.health_assessments.pluck(:id, :health_scorecard_version_id)

    rollback_version(original, expected_current_version_id: version.id)
    assessment = AccountHealth.recalculate!(workspace: @workspace, account: @account,
      trigger_kind: "human_request", membership: @owner, at: @at + 1.day)

    assert_equal original, assessment.health_scorecard_version
    assert_equal prior_ids, @account.health_assessments.where(id: prior_ids.map(&:first)).pluck(:id, :health_scorecard_version_id)
    assert AuditEvent.exists?(action: "scorecard.rolled_back", subject_type: original.class.name,
      subject_id: original.id, actor: @owner.user)
  end

  test "enforces role tenant and append-only boundaries" do
    manager = @workspace.memberships.create!(user: users(:teammate), role: :manager)
    version = propose
    HealthScorecardBacktester.run!(workspace: @workspace, membership: manager, version:, at: @at)
    assert_raises(Current::RoleAccessDenied) do
      HealthScorecardPublisher.publish!(workspace: @workspace, membership: manager, version:,
        expected_current_version_id: @scorecard.current_version_id, expected_backtest_id: latest_backtest_id(version))
    end
    assert_raises(ActiveRecord::RecordNotFound) do
      HealthScorecardBacktester.run!(workspace: workspaces(:beta_support), membership: memberships(:outsider_beta),
        version:, at: @at)
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      HealthScorecardVersion.transaction(requires_new: true) do
        HealthScorecardVersion.where(id: version.id).update_all(explanation: "Changed")
      end
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      HealthScorecardBacktest.transaction(requires_new: true) { HealthScorecardBacktest.connection.execute("TRUNCATE health_scorecard_backtests") }
    end
  end

  test "treats the latest generated_at preview as inspected even if a later row has an earlier clock" do
    version = propose(weights: { "open_cases" => 40 })
    inspected = HealthScorecardBacktester.run!(workspace: @workspace, membership: @owner, version:, at: @at + 2.hours)
    later_row = HealthScorecardBacktester.run!(workspace: @workspace, membership: @owner, version:, at: @at + 1.hour)

    assert_operator later_row.created_at, :>=, inspected.created_at
    assert_operator later_row.generated_at, :<, inspected.generated_at
    error = assert_raises(HealthScorecardPublisher::InvalidPublish) do
      HealthScorecardPublisher.publish!(workspace: @workspace, membership: @owner, version:,
        expected_current_version_id: @scorecard.current_version_id, expected_backtest_id: later_row.id)
    end
    assert_match(/not the inspected backtest/i, error.message)
    assert_equal version, publish_version(version, expected_backtest_id: inspected.id)
  end

  test "rejects publish when retained snapshots change after the inspected preview" do
    version = propose(weights: { "open_cases" => 40 })
    backtest = HealthScorecardBacktester.run!(workspace: @workspace, membership: @owner, version:, at: @at)
    AccountHealth.recalculate!(workspace: @workspace, account: @account,
      trigger_kind: "schedule", membership: @owner, at: @at + 1.day)

    error = assert_raises(HealthScorecardPublisher::InvalidPublish) do
      HealthScorecardPublisher.publish!(workspace: @workspace, membership: @owner, version:,
        expected_current_version_id: @scorecard.current_version_id, expected_backtest_id: backtest.id)
    end
    assert_match(/snapshots changed/i, error.message)
    refreshed = HealthScorecardBacktester.run!(workspace: @workspace, membership: @owner, version:, at: @at + 2.days)
    assert_equal version, publish_version(version, expected_backtest_id: refreshed.id)
  end

  test "an accepted runner proposal still requires the inspected preview before publish" do
    approve_scripted_runtime(workspace: @workspace, membership: @owner)
    run = HealthScorecardProposalWorkflow.generate!(
      workspace: @workspace, membership: @owner,
      prompt: "Make approaching renewal and repeated SLA breaches matter more.", admit: false
    )
    proposal = complete_scorecard_proposal(run)
    version = HealthScorecardProposalWorkflow.accept!(workspace: @workspace, membership: @owner, proposal:)
    assert_equal proposal, version.source_proposal
    assert_raises(HealthScorecardPublisher::InvalidPublish) do
      HealthScorecardPublisher.publish!(workspace: @workspace, membership: @owner, version:,
        expected_current_version_id: @scorecard.current_version_id, expected_backtest_id: nil)
    end
    HealthScorecardBacktester.run!(workspace: @workspace, membership: @owner, version:, at: @at)
    assert_equal version, publish_version(version)
    assert_equal version, @scorecard.reload.current_version
  end

  private
    def propose(healthy_min: 75, watch_min: 50, weights: { "open_cases" => 20 })
      HealthScorecardDesigner.propose!(workspace: @workspace, membership: @owner,
        prompt: "Focus the score on clear renewal risk.", healthy_min:, watch_min:, weights:)
    end

    def latest_backtest_id(version)
      version.backtests.order(generated_at: :desc, id: :desc).pick(:id)
    end

    def publish_version(version, expected_current_version_id: @scorecard.reload.current_version_id,
      expected_backtest_id: latest_backtest_id(version))
      HealthScorecardPublisher.publish!(workspace: @workspace, membership: @owner, version:,
        expected_current_version_id:, expected_backtest_id:)
    end

    def rollback_version(version, expected_current_version_id:)
      HealthScorecardPublisher.rollback!(workspace: @workspace, membership: @owner, version:,
        expected_current_version_id:, expected_backtest_id: latest_backtest_id(version))
    end

    def complete_scorecard_proposal(run)
      ledger = ExecutionLedger.new(workspace: @workspace)
      time = Time.current.change(usec: 0)
      output = JSON.generate(
        schema_version: 1, kind: "scorecard_proposal",
        definition: {
          "schema_version" => 1, "healthy_min" => 75, "watch_min" => 50,
          "rules" => [
            { "signal_key" => "renewal_on", "weight" => 40 },
            { "signal_key" => "sla_breaches", "weight" => 35 }
          ]
        },
        explanation: "I increased renewal proximity and SLA breach weights using only catalog signals.",
        assumptions: [ "Only retained catalog signals can change the score." ],
        unsupported_requests: [], missing_evidence: []
      )
      [
        [ 1, "run.admitted", { workspace_key: @workspace.runner_key, task_key: run.crew_task.task_key, attempt: 1 } ],
        [ 2, "run.started", { adapter: "scripted", scenario: "scorecard", attempt: 1 } ],
        [ 3, "output.produced", { text: output } ],
        [ 4, "run.completed", { outcome: "completed" } ]
      ].each do |sequence, type, data|
        ledger.ingest!(event: {
          "protocol_version" => "v1", "event_id" => SecureRandom.uuid, "run_id" => run.run_key,
          "sequence" => sequence, "event_type" => type,
          "occurred_at" => (time + sequence.seconds).iso8601(6), "data" => data.deep_stringify_keys
        })
      end
      @workspace.health_scorecard_proposals.find_by!(execution_run: run)
    end

    def create_backtest_assessment(account, calculated_at:, open_cases: 0)
      assessment = account.health_assessments.create!(
        workspace: @workspace, score: 100, risk_level: "healthy", trigger_kind: "schedule",
        material_change: false, health_scorecard_version: @scorecard.current_version, calculated_at:
      )
      assessment.signals.create!(
        workspace: @workspace, signal_key: "open_cases", value_kind: "number", numeric_value: open_cases,
        weight: 0, risk_points: 0, source_kind: "support_cases", source_locator: "account://#{account.id}/cases",
        range_ends_at: calculated_at
      )
      assessment
    end
end
