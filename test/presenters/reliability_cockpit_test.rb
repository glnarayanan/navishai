require "test_helper"

class ReliabilityCockpitTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
    @now = Time.zone.parse("2026-08-28 15:00:00 UTC")
  end

  test "reports unavailable Workspace-specific queue evidence without global metrics" do
    cockpit = ReliabilityCockpit.build(workspace: @workspace, membership: @owner, now: @now)

    queue = cockpit.groups.index_by(&:key).fetch("queue")
    item = queue.items.sole
    assert_equal "not_configured", queue.status
    assert_equal "Workspace-specific queue evidence is unavailable because the queue is shared.", queue.summary
    assert_equal queue.summary, item.summary
    assert_equal "Shared queue state is intentionally excluded from Workspace health.", item.detail
    assert_nil item.occurred_at
    assert_nil item.record
    assert_nil item.action
    data = cockpit.groups.index_by(&:key).fetch("data")
    checks = data.items.index_by(&:key)
    assert_equal "not_configured", checks.fetch("backup_verification").status
    assert_equal "not_configured", checks.fetch("restore_rehearsal").status
  end

  test "does not let global queue state or foreign execution records alter the current cockpit" do
    foreign_workspace = workspaces(:beta_support)
    create_foreign_execution_records(foreign_workspace)
    baseline = cockpit_projection(build_cockpit)

    global_states = [
      { ready_count: 0, overdue_count: 0, failed_count: 0, claimed_count: 0, heartbeat_at: nil },
      { ready_count: 8, overdue_count: 3, failed_count: 5, claimed_count: 2, heartbeat_at: @now - 5.minutes }
    ]
    global_states.each do |state|
      reads = []
      projected = with_global_queue_state(state, reads) { cockpit_projection(build_cockpit) }

      assert_equal baseline, projected
      assert_empty reads
    end
  end

  test "surfaces failed checks, stale connectors, index failure, and bounded detail" do
    inbox = @workspace.shared_email_inboxes.create!(
      name: "Stale inbox", email_address: "stale@example.com", credential_key: "stale"
    )
    inbox.inbound_email_deliveries.create!(
      workspace: @workspace, source_message_id: "stale@example.com",
      content_sha256: Digest::SHA256.hexdigest("stale"), raw_email: "stale",
      status: :failed, failure_code: "missing_sender", received_at: @now - 2.days,
      processed_at: @now - 2.days
    )
    memory = create_memory("Cockpit source")
    @workspace.memory_index_entries.create!(
      memory_record: memory, status: :failed, attempt_count: 1,
      failure_code: "remote_unavailable", last_attempted_at: @now - 10.minutes
    )
    OperationalCheck.record!(
      workspace: @workspace, membership: @owner, check_kind: "backup_verification",
      result: "failed", result_code: "checksum_mismatch",
      evidence_digest: Digest::SHA256.hexdigest("failed check"), source_commit: "b" * 40,
      checked_at: @now - 1.hour
    )

    cockpit = ReliabilityCockpit.build(workspace: @workspace, membership: @owner, now: @now)
    groups = cockpit.groups.index_by(&:key)
    assert_equal "blocked", groups.fetch("connectors").status
    assert_equal "blocked", groups.fetch("memory").status
    backup = groups.fetch("data").items.index_by(&:key).fetch("backup_verification")
    assert_equal "blocked", backup.status
    assert_match(/Checksum mismatch/, backup.summary)
    assert_operator cockpit.groups.sum { |group| group.items.size }, :<=,
      2 + (ReliabilityCockpit::DETAIL_LIMIT * 4)
  end

  test "distinguishes a stale ready connector from a replayed delivery" do
    key = "NAVISHAI_SHARED_EMAIL_READY_STALE_WEBHOOK_SECRET"
    original = ENV[key]
    ENV[key] = "s" * 32
    inbox = @workspace.shared_email_inboxes.create!(
      name: "Ready but stale", email_address: "ready-stale@example.com", credential_key: "ready_stale"
    )
    support_case = create_support_case(workspace: @workspace, membership: @owner)
    message = add_inbound_message(support_case, occurred_at: @now - 2.days)
    inbox.inbound_email_deliveries.create!(
      workspace: @workspace, source_message_id: "replayed@example.com",
      content_sha256: Digest::SHA256.hexdigest("replayed"), raw_email: "replayed",
      conversation: support_case.conversation, conversation_message: message,
      status: :processed, attempt_count: 1, received_at: @now - 2.days,
      last_attempted_at: @now - 2.days, processed_at: @now - 2.days
    )

    cockpit = ReliabilityCockpit.build(workspace: @workspace, membership: @owner, now: @now)

    connectors = cockpit.groups.index_by(&:key).fetch("connectors")
    item = connectors.items.find { |candidate| candidate.record == inbox }
    assert_equal "attention", item.status
    assert_match(/older than 24 hours/, item.summary)
    assert_match(/1 replayed inbound delivery/, connectors.summary)
  ensure
    original ? ENV[key] = original : ENV.delete(key)
  end

  test "keeps an unhealthy runtime visible beyond the healthy detail cap" do
    ReliabilityCockpit::DETAIL_LIMIT.times do |index|
      create_runtime("healthy_#{index}", approved: true)
    end
    blocked = create_runtime("blocked_after_cap", health_status: "unhealthy")

    execution = ReliabilityCockpit.build(workspace: @workspace, membership: @owner, now: @now)
      .groups.index_by(&:key).fetch("execution")

    assert_equal "blocked", execution.status
    assert_includes execution.items.map(&:record), blocked
    assert_equal ReliabilityCockpit::DETAIL_LIMIT, execution.items.count { |item| item.record.is_a?(RuntimeInstallation) }
  end

  test "denies non-managers and foreign memberships at the read seam" do
    member = @workspace.memberships.create!(
      user: User.create!(email_address: "cockpit-member@example.com", password: "password12345", verified_at: Time.current),
      role: :member
    )
    assert_raises(Current::RoleAccessDenied) do
      ReliabilityCockpit.build(workspace: @workspace, membership: member)
    end
    assert_raises(ActiveRecord::RecordNotFound) do
      ReliabilityCockpit.build(
        workspace: @workspace, membership: memberships(:teammate_success)
      )
    end
  end

  private
    def build_cockpit
      ReliabilityCockpit.build(workspace: @workspace, membership: @owner, now: @now)
    end

    def cockpit_projection(cockpit)
      {
        overall_status: cockpit.overall_status,
        status_counts: cockpit.status_counts,
        groups: cockpit.groups.map do |group|
          {
            key: group.key, title: group.title, status: group.status, summary: group.summary,
            items: group.items.map do |item|
              [ item.key, item.title, item.status, item.summary, item.detail, item.occurred_at,
                item.record && [ item.record.class.name, item.record.id ], item.action ]
            end
          }
        end
      }
    end

    def create_foreign_execution_records(workspace)
      membership = memberships(:outsider_beta)
      install_crew_test_dependencies(workspace:, membership:)
      support_case = create_support_case(workspace:, contact: contacts(:bob), membership:)
      profile = workspace.agent_profiles.find_by!(role_key: "support_investigator")

      %w[admitting running failed].each_with_index do |status, index|
        task = CrewWork.create!(
          workspace:, membership:, scope: support_case, profile:,
          title: "Foreign execution #{index}", input_context: "Use retained facts.",
          expected_output: "Return a finding."
        )
        run = ExecutionLedger.new(workspace:).prepare!(
          task:, request_key: "reliability-foreign-#{index}"
        )
        next if status == "admitting"

        ledger = ExecutionLedger.new(workspace:)
        ingest_foreign_event(ledger, run, 1, "run.admitted",
          workspace_key: workspace.runner_key, task_key: task.task_key, attempt: run.attempt_number)
        ingest_foreign_event(ledger, run, 2, "run.started",
          adapter: run.selected_adapter_key, scenario: "reliability", attempt: run.attempt_number)
        if status == "failed"
          ingest_foreign_event(ledger, run, 3, "run.failed", code: "foreign_failure", retryable: false)
        end
      end
    end

    def ingest_foreign_event(ledger, run, sequence, event_type, **data)
      ledger.ingest!(event: {
        "protocol_version" => "v1", "event_id" => SecureRandom.uuid, "run_id" => run.run_key,
        "sequence" => sequence, "event_type" => event_type,
        "occurred_at" => (Time.current - (10 - sequence).minutes).iso8601(6),
        "data" => data.deep_stringify_keys
      })
    end

    def with_global_queue_state(state, reads)
      relation = Object.new
      relation.define_singleton_method(:count) do
        reads << :scheduled_count
        state.fetch(:overdue_count)
      end

      readers = [
        [ SolidQueue::ReadyExecution, :count, -> { reads << :ready_count; state.fetch(:ready_count) } ],
        [ SolidQueue::ReadyExecution, :minimum, ->(*) { reads << :ready_minimum; nil } ],
        [ SolidQueue::ScheduledExecution, :where, ->(*) { reads << :scheduled_where; relation } ],
        [ SolidQueue::FailedExecution, :count, -> { reads << :failed_count; state.fetch(:failed_count) } ],
        [ SolidQueue::ClaimedExecution, :count, -> { reads << :claimed_count; state.fetch(:claimed_count) } ],
        [ SolidQueue::Process, :maximum, ->(*) { reads << :heartbeat; state[:heartbeat_at] } ]
      ]
      originals = readers.map do |klass, method_name, implementation|
        original = klass.method(method_name)
        klass.define_singleton_method(method_name, &implementation)
        [ klass, method_name, original ]
      end

      yield
    ensure
      originals&.reverse_each do |klass, method_name, original|
        klass.define_singleton_method(method_name, &original)
      end
    end

    def create_runtime(key, approved: false, health_status: "available")
      @workspace.runtime_installations.create!(
        detection_key: Digest::SHA256.hexdigest(key), adapter_key: key,
        protocol_version: "v1", transport: "built_in_https", execution_mode: "bounded", executable_path: "/opt/navishai/#{key}",
        executable_version: key, account_metadata: {}, capabilities: [],
        minimum_version: "1", maximum_version: "1", compatibility_status: "compatible",
        incompatibility_reason: "", health_status:, checked_at: @now,
        runtime_test_status: approved ? "passed" : "untested",
        runtime_tested_at: approved ? @now : nil,
        runtime_tested_configuration_fingerprint: approved ? "0" * 64 : nil,
        approved:, approved_by_membership: approved ? @owner : nil,
        approved_by_user: approved ? @owner.user : nil, approved_at: approved ? @now : nil
      )
    end

    def create_memory(content)
      @workspace.memory_records.create!(
        memory_type: :semantic, scope_kind: :workspace, topic: "reliability",
        content:, authority: :source_record, origin_kind: :system,
        source_reference: "test://reliability", source_digest: Digest::SHA256.hexdigest(content),
        observed_at: @now - 1.day, valid_from: @now - 1.day, confidence: 1,
        retention_policy: :indefinite
      )
    end
end
