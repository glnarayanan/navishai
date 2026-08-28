require "test_helper"

class ReliabilityCockpitTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
    @now = Time.zone.parse("2026-08-28 15:00:00 UTC")
  end

  test "uses explicit queue thresholds and never treats absent evidence as healthy" do
    cockpit = ReliabilityCockpit.build(
      workspace: @workspace, membership: @owner, now: @now,
      queue_snapshot: {
        status: "blocked", ready_count: 8, overdue_count: 3, failed_count: 1,
        oldest_ready_at: @now - 3.minutes, last_heartbeat_at: @now - 5.minutes
      }
    )

    queue = cockpit.groups.index_by(&:key).fetch("queue")
    assert_equal "blocked", queue.status
    assert_equal "8 ready jobs, 3 overdue jobs, and 1 failed job.", queue.summary
    data = cockpit.groups.index_by(&:key).fetch("data")
    checks = data.items.index_by(&:key)
    assert_equal "not_configured", checks.fetch("backup_verification").status
    assert_equal "not_configured", checks.fetch("restore_rehearsal").status
    assert_equal "blocked", cockpit.overall_status
  end

  test "does not infer queue health from an empty queue without a fresh worker heartbeat" do
    unknown = ReliabilityCockpit.build(
      workspace: @workspace, membership: @owner, now: @now,
      queue_snapshot: {
        status: "unknown", ready_count: 0, overdue_count: 0, failed_count: 0,
        oldest_ready_at: nil, last_heartbeat_at: nil
      }
    ).groups.index_by(&:key).fetch("queue")
    attention = ReliabilityCockpit.build(
      workspace: @workspace, membership: @owner, now: @now,
      queue_snapshot: {
        status: "attention", ready_count: 0, overdue_count: 0, failed_count: 0,
        oldest_ready_at: nil, last_heartbeat_at: @now - 2.minutes
      }
    ).groups.index_by(&:key).fetch("queue")

    assert_equal "unknown", unknown.status
    assert_equal "attention", attention.status
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

    cockpit = ReliabilityCockpit.build(
      workspace: @workspace, membership: @owner, now: @now,
      queue_snapshot: { status: "healthy", ready_count: 0, overdue_count: 0, failed_count: 0,
        oldest_ready_at: nil, last_heartbeat_at: @now }
    )
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

    cockpit = ReliabilityCockpit.build(
      workspace: @workspace, membership: @owner, now: @now,
      queue_snapshot: { status: "not_configured" }
    )

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

    execution = ReliabilityCockpit.build(
      workspace: @workspace, membership: @owner, now: @now,
      queue_snapshot: { status: "not_configured" }
    ).groups.index_by(&:key).fetch("execution")

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
      ReliabilityCockpit.build(workspace: @workspace, membership: member, queue_snapshot: { status: "not_configured" })
    end
    assert_raises(ActiveRecord::RecordNotFound) do
      ReliabilityCockpit.build(
        workspace: @workspace, membership: memberships(:teammate_success),
        queue_snapshot: { status: "not_configured" }
      )
    end
  end

  private
    def create_runtime(key, approved: false, health_status: "available")
      @workspace.runtime_installations.create!(
        detection_key: Digest::SHA256.hexdigest(key), adapter_key: key,
        protocol_version: "v1", executable_path: "/opt/navishai/#{key}",
        executable_version: key, account_metadata: {}, capabilities: [],
        minimum_version: "1", maximum_version: "1", compatibility_status: "compatible",
        incompatibility_reason: "", health_status:, checked_at: @now,
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
