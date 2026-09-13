require "test_helper"

class AuditEventTest < ActiveSupport::TestCase
  test "records workspace-scoped actor and subject metadata" do
    event = AuditEvent.record!(
      action: "workspace_invitation.created",
      source: :web,
      workspace: workspaces(:acme_support),
      actor: users(:owner),
      subject: workspace_invitations(:pending_member),
      metadata: { role: "member" },
      request_id: "request-123",
      ip_address: "192.0.2.10"
    )

    assert event.user?
    assert_equal workspaces(:acme_support), event.workspace
    assert_equal users(:owner), event.actor
    assert_equal "WorkspaceInvitation", event.subject_type
    assert_equal workspace_invitations(:pending_member).id, event.subject_id
    assert_equal({ "role" => "member" }, event.metadata)
  end

  test "infers break-glass, anonymous, and system actors" do
    break_glass_user = users(:owner)
    break_glass_user.update!(break_glass: true)

    recovery = AuditEvent.record!(action: "authentication.succeeded", source: :web, actor: break_glass_user)
    anonymous = AuditEvent.record!(action: "authentication.failed", source: :web)
    system = AuditEvent.record!(action: "installation.bootstrapped", source: :system, actor_kind: :system)

    assert recovery.break_glass?
    assert anonymous.anonymous?
    assert system.system?
  end

  test "persisted events are read only" do
    event = AuditEvent.record!(action: "authentication.failed", source: :web)

    assert_raises(ActiveRecord::ReadOnlyRecord) { event.update!(action: "authentication.succeeded") }
    assert_raises(ActiveRecord::ReadOnlyRecord) { event.destroy! }
  end

  test "database rejects direct mutation" do
    event = AuditEvent.record!(action: "authentication.failed", source: :web)

    update_error = assert_raises(ActiveRecord::StatementInvalid) do
      AuditEvent.transaction(requires_new: true) do
        AuditEvent.connection.execute("UPDATE audit_events SET action = 'changed' WHERE id = #{event.id}")
      end
    end
    delete_error = assert_raises(ActiveRecord::StatementInvalid) do
      AuditEvent.transaction(requires_new: true) do
        AuditEvent.connection.execute("DELETE FROM audit_events WHERE id = #{event.id}")
      end
    end
    truncate_error = assert_raises(ActiveRecord::StatementInvalid) do
      AuditEvent.transaction(requires_new: true) do
        AuditEvent.connection.execute("TRUNCATE customer_success_intervention_due_notices, audit_events")
      end
    end

    assert_includes update_error.message, "audit events are append-only"
    assert_includes delete_error.message, "audit events are append-only"
    assert_includes truncate_error.message, "audit events are append-only"
  end

  test "rejects sensitive or oversized metadata" do
    sensitive = AuditEvent.new(
      action: "authentication.failed",
      source: :web,
      actor_kind: :anonymous,
      occurred_at: Time.current,
      metadata: { context: { access_token: "do-not-store" } }
    )
    oversized = sensitive.dup
    oversized.metadata = { detail: "x" * (AuditEvent::MAX_METADATA_BYTES + 1) }

    assert_not sensitive.valid?
    assert_includes sensitive.errors[:metadata], "contains a sensitive key"
    assert_not oversized.valid?
    assert_includes oversized.errors[:metadata], "is too large"
  end

  test "rejects unregistered actions, metadata keys, and structured values" do
    unknown_action = AuditEvent.new(action: "unknown.action", source: :web, actor_kind: :anonymous, occurred_at: Time.current)
    unknown_key = AuditEvent.new(action: "authentication.failed", source: :web, actor_kind: :anonymous, occurred_at: Time.current, metadata: { reason: "invalid" })
    structured_value = AuditEvent.new(action: "authentication.failed", source: :web, actor_kind: :anonymous, occurred_at: Time.current, metadata: { method: [ "local" ] })

    assert_not unknown_action.valid?
    assert_not unknown_key.valid?
    assert_includes unknown_key.errors[:metadata], "contains an unsupported key"
    assert_not structured_value.valid?
    assert_includes structured_value.errors[:metadata], "contains a non-scalar value"
  end

  test "derives actor kind and rejects unsupported metadata values" do
    event = AuditEvent.record!(
      action: "authentication.succeeded",
      source: :web,
      actor: users(:owner),
      actor_kind: :break_glass,
      metadata: { method: "local" }
    )
    unsafe_value = AuditEvent.new(
      action: "authentication.succeeded",
      source: :web,
      actor: users(:owner),
      actor_kind: :user,
      occurred_at: Time.current,
      metadata: { method: "owner@example.com" }
    )

    assert event.user?
    assert_not unsafe_value.valid?
    assert_includes unsafe_value.errors[:metadata], "contains an unsupported value"
  end

  test "rejects a subject from another workspace" do
    assert_raises(ArgumentError) do
      AuditEvent.record!(
        action: "workspace_invitation.created",
        source: :web,
        workspace: workspaces(:beta_support),
        subject: workspace_invitations(:pending_member),
        metadata: { role: "member" }
      )
    end
  end

  test "workspace scope does not return another tenant's events" do
    own_event = AuditEvent.record!(action: "workspace_invitation.created", source: :web, workspace: workspaces(:acme_support), metadata: { role: "member" })
    AuditEvent.record!(action: "workspace_invitation.created", source: :web, workspace: workspaces(:beta_support), metadata: { role: "member" })

    assert_equal [ own_event ], AuditEvent.for_workspace(workspaces(:acme_support))
  end

  test "helpdesk actions reject customer text and unsupported state values" do
    safe = AuditEvent.new(
      action: "case.status_changed",
      source: :web,
      actor: users(:owner),
      actor_kind: :user,
      occurred_at: Time.current,
      metadata: { from_status: "triaged", to_status: "investigating" }
    )
    customer_text = safe.dup
    customer_text.metadata = { from_status: "triaged", to_status: "investigating", body: "customer text" }
    invalid_state = safe.dup
    invalid_state.metadata = { from_status: "triaged", to_status: "deleted" }

    assert safe.valid?
    assert_not customer_text.valid?
    assert_includes customer_text.errors[:metadata], "contains an unsupported key"
    assert_not invalid_state.valid?
    assert_includes invalid_state.errors[:metadata], "contains an unsupported value"
  end
end
