require "test_helper"

class WorkspaceContentExpiryTest < ActiveSupport::TestCase
  test "request is owner attributed and idempotent while pending" do
    workspace = workspaces(:acme_support)
    policy = workspace.create_workspace_data_policy!(content_retention_days: 30, audit_retention_days: 365)
    now = Time.zone.parse("2026-08-24 12:00:00")

    assert_difference [ "WorkspaceContentExpiryRun.count", "AuditEvent.count" ], 1 do
      @run = WorkspaceContentExpiry.request!(
        workspace:, membership: memberships(:owner_support), source: :web, requested_at: now
      )
    end

    assert_equal now - policy.content_retention_days.days, @run.cutoff_at
    enqueued_count = ActiveJob::Base.queue_adapter.enqueued_jobs.count
    assert_equal @run, WorkspaceContentExpiry.request!(
      workspace:, membership: memberships(:owner_support), source: :web, requested_at: now
    )
    assert_equal enqueued_count, ActiveJob::Base.queue_adapter.enqueued_jobs.count
    audit = AuditEvent.order(:id).last
    assert_equal "workspace.content_expiry_requested", audit.action
    assert_equal users(:owner), audit.actor
  end

  test "database expiry removes plaintext but preserves another workspace and audit history" do
    workspace = workspaces(:acme_support)
    other_workspace = workspaces(:beta_support)
    message = ConversationThread.start_inbound!(
      workspace:, contact: contacts(:alice), subject: "Private subject", body: "Private body",
      occurred_at: Time.current, source: :integration
    )
    other_message = ConversationThread.start_inbound!(
      workspace: other_workspace, contact: contacts(:bob), subject: "Other subject", body: "Other body",
      occurred_at: Time.current, source: :integration
    )
    original_audit_count = workspace.audit_events.count
    original_other_body = other_message.body
    cutoff = 1.day.from_now

    count = ActiveRecord::Base.connection.select_value(
      "SELECT expire_workspace_content(#{workspace.id}, #{ActiveRecord::Base.connection.quote(cutoff)})"
    ).to_i

    assert_operator count, :>, 0
    assert_equal "[Expired by retention policy]", message.reload.body
    assert_equal original_other_body, other_message.reload.body
    assert_equal original_audit_count, workspace.audit_events.count
    assert_match(/expired-/, workspace.source_identity_keys.first.reload.normalized_value)
  end

  test "external cleanup failure leaves database content and records a visible failure" do
    workspace = workspaces(:acme_support)
    message = ConversationThread.start_inbound!(
      workspace:, contact: contacts(:alice), subject: "Private subject", body: "Private body",
      occurred_at: Time.current, source: :integration
    )
    original_body = message.body
    run = workspace.workspace_content_expiry_runs.create!(cutoff_at: 1.day.from_now)

    purger = ->(*) { raise SupermemoryEngine::Unavailable, "offline" }
    WorkspaceContentExpiry.perform!(run:, object_purger: purger)

    assert run.reload.failed?
    assert_equal "unavailable", run.failure_code
    assert_equal original_body, message.reload.body
    audit = workspace.audit_events.order(:id).last
    assert_equal "workspace.content_expiry_failed", audit.action
    assert_equal({ "failure_code" => "unavailable" }, audit.metadata)
  end

  test "expiry makes a pending index entry terminal based on memory age" do
    workspace = workspaces(:acme_support)
    memory = workspace.memory_records.create!(
      memory_type: :episodic, scope_kind: :workspace, topic: "old-memory", content: "Private old memory",
      authority: :source_record, origin_kind: :system, source_reference: "test://old-memory",
      source_digest: Digest::SHA256.hexdigest("old-memory"), observed_at: 3.days.ago,
      valid_from: 3.days.ago, confidence: 1, retention_policy: :indefinite
    )
    entry = workspace.memory_index_entries.create!(memory_record: memory)
    run = workspace.workspace_content_expiry_runs.create!(cutoff_at: 2.days.ago)

    WorkspaceContentExpiry.perform!(run:, object_purger: ->(*) { })

    assert entry.reload.failed?
    assert_equal "retention_expired", entry.failure_code
    engine = Object.new
    engine.define_singleton_method(:index) { |**| flunk "expired memory must never be indexed" }
    MemoryIndexer.perform!(entry:, engine:)
  end
end
