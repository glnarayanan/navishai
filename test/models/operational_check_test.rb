require "test_helper"

class OperationalCheckTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
    @attributes = {
      workspace: @workspace,
      check_kind: "backup_verification",
      result: "passed",
      result_code: "verified",
      evidence_digest: Digest::SHA256.hexdigest("bounded backup evidence"),
      source_commit: "a" * 40,
      checked_at: Time.zone.parse("2026-08-28 12:00:00 UTC"),
      archive_format: "navishai-backup-v1",
      counts: { table: 4, record: 120, attachment: 3, memory: 8 }
    }
  end

  test "records one bounded user-attributed check and matching audit" do
    assert_difference [ "OperationalCheck.count", "AuditEvent.count" ], 1 do
      @check = OperationalCheck.record!(**@attributes, membership: @owner)
    end

    assert_equal @owner, @check.recorded_by_membership
    assert_equal @owner.user, @check.recorded_by_user
    assert_equal 120, @check.record_count
    audit = @workspace.audit_events.find_by!(action: "operations.check_recorded", subject_id: @check.id)
    assert_equal @owner.user, audit.actor
    assert_equal({ "check_kind" => "backup_verification", "result" => "passed" }, audit.metadata)
    assert_not_includes @check.attributes.to_json, "bounded backup evidence"
  end

  test "records a system check without inventing a human actor" do
    check = OperationalCheck.record!(**@attributes.merge(result: "unavailable", result_code: "host_unavailable"))

    assert_nil check.recorded_by_membership
    assert_nil check.recorded_by_user
    audit = @workspace.audit_events.find_by!(action: "operations.check_recorded", subject_id: check.id)
    assert audit.system?
    assert audit.source_system?
  end

  test "rejects invalid bounds, foreign actors, and non-manager actors" do
    member = @workspace.memberships.create!(
      user: User.create!(email_address: "check-member@example.com", password: "password12345", verified_at: Time.current),
      role: :member
    )
    assert_raises(Current::RoleAccessDenied) do
      OperationalCheck.record!(**@attributes, membership: member)
    end
    assert_raises(ActiveRecord::RecordNotFound) do
      OperationalCheck.record!(**@attributes, membership: memberships(:teammate_success))
    end

    invalid = OperationalCheck.new(
      @attributes.except(:counts).merge(
        result_code: "Secret value", evidence_digest: "bad", source_commit: "bad",
        record_count: -1
      )
    )
    refute invalid.valid?
    assert invalid.errors[:result_code].any?
    assert invalid.errors[:evidence_digest].any?
    assert invalid.errors[:source_commit].any?
    assert invalid.errors[:record_count].any?

    mismatched_user = User.create!(
      email_address: "mismatched-check-actor@example.com", password: "password12345", verified_at: Time.current
    )
    assert_raises(ActiveRecord::InvalidForeignKey) do
      OperationalCheck.insert_all!([ {
        workspace_id: @workspace.id, check_kind: "backup_verification", result: "passed",
        result_code: "verified", evidence_digest: "a" * 64, source_commit: "b" * 40,
        recorded_by_membership_id: @owner.id, recorded_by_user_id: mismatched_user.id,
        checked_at: Time.current, created_at: Time.current, updated_at: Time.current
      } ])
    end
  end

  test "database protection keeps every recorded check append only" do
    check = OperationalCheck.record!(**@attributes, membership: @owner)

    error = assert_raises(ActiveRecord::StatementInvalid) do
      OperationalCheck.transaction(requires_new: true) do
        OperationalCheck.where(id: check.id).update_all(result: "failed")
      end
    end
    assert_match(/append only/, error.message)
    assert_equal "passed", check.reload.result
  end
end
