require "test_helper"

class CustomerRecordMergerTest < ActiveSupport::TestCase
  test "merge keeps identities on their original record while resolving to the target" do
    source = accounts(:acme_duplicate)
    target = accounts(:acme)
    identity = create_matched_identity(source, "duplicate-account", domain: "duplicate.example")

    assert_difference [ "AccountMerge.count", "AuditEvent.count" ], 1 do
      selected = CustomerRecordMerger.merge!(
        workspace: source.workspace,
        source: source,
        target: target,
        membership: memberships(:owner_support)
      )
      assert_equal target, selected
    end

    assert_equal source, identity.reload.direct_record
    assert_equal target, identity.canonical_record
    assert_equal "account.merged", AuditEvent.order(:id).last.action
  end

  test "unmerge closes history and restores identities without moving later target facts" do
    source = accounts(:acme_duplicate)
    target = accounts(:acme)
    old_identity = create_matched_identity(source, "old-account", domain: "old.example")
    CustomerRecordMerger.merge!(workspace: source.workspace, source: source, target: target, membership: memberships(:owner_support))
    new_identity = create_matched_identity(target, "new-account", domain: "new.example")

    assert_difference "AuditEvent.count", 1 do
      restored = CustomerRecordMerger.unmerge!(workspace: source.workspace, source: source, membership: memberships(:owner_support))
      assert_equal source, restored
    end

    assert_equal source, old_identity.canonical_record
    assert_equal target, new_identity.canonical_record
    assert AccountMerge.where(source: source).sole.unmerged_at?
    assert_equal "account.unmerged", AuditEvent.order(:id).last.action
  end

  test "unmerge restores an alias subtree" do
    child = Account.create!(workspace: workspaces(:acme_support), name: "Child duplicate")
    source = accounts(:acme_duplicate)
    target = accounts(:acme)
    CustomerRecordMerger.merge!(workspace: source.workspace, source: child, target: source, membership: memberships(:owner_support))
    CustomerRecordMerger.merge!(workspace: source.workspace, source: source, target: target, membership: memberships(:owner_support))

    assert_equal target, child.canonical

    CustomerRecordMerger.unmerge!(workspace: source.workspace, source: source, membership: memberships(:owner_support))

    assert_equal source, child.canonical
  end

  test "contact merge requires the same effective account" do
    assert_raises(ArgumentError) do
      CustomerRecordMerger.merge!(
        workspace: workspaces(:acme_support),
        source: contacts(:alice_duplicate),
        target: contacts(:alice),
        membership: memberships(:owner_support)
      )
    end

    contacts(:alice_duplicate).update!(account: accounts(:acme))
    assert_equal contacts(:alice), CustomerRecordMerger.merge!(
      workspace: workspaces(:acme_support),
      source: contacts(:alice_duplicate),
      target: contacts(:alice),
      membership: memberships(:owner_support)
    )
  end

  test "merge fails closed for another workspace and insufficient role" do
    assert_no_difference [ "AccountMerge.count", "AuditEvent.count" ] do
      assert_raises(ActiveRecord::RecordNotFound) do
        CustomerRecordMerger.merge!(
          workspace: workspaces(:acme_support),
          source: accounts(:acme_duplicate),
          target: accounts(:beta),
          membership: memberships(:owner_support)
        )
      end
    end

    member = Membership.create!(workspace: workspaces(:acme_support), user: users(:outsider), role: :member)
    assert_raises(Current::RoleAccessDenied) do
      CustomerRecordMerger.merge!(
        workspace: workspaces(:acme_support),
        source: accounts(:acme_duplicate),
        target: accounts(:acme),
        membership: member
      )
    end
  end

  test "audit failure rolls back merge history" do
    singleton = AuditEvent.singleton_class
    original_record = AuditEvent.method(:record!)
    singleton.define_method(:record!) { |**| raise ActiveRecord::RecordInvalid, AuditEvent.new }

    assert_no_difference "AccountMerge.count" do
      assert_raises(ActiveRecord::RecordInvalid) do
        CustomerRecordMerger.merge!(
          workspace: workspaces(:acme_support),
          source: accounts(:acme_duplicate),
          target: accounts(:acme),
          membership: memberships(:owner_support)
        )
      end
    end
  ensure
    singleton&.define_method(:record!, original_record) if original_record
  end

  private
    def create_matched_identity(record, source_record_id, domain:)
      identity = SourceIdentity.create!(
        workspace: record.workspace,
        entity_kind: :account,
        source_namespace: "manual_import",
        source_record_type: :company,
        source_record_id: source_record_id,
        status: :matched,
        account: record,
        resolution_method: :created,
        resolved_at: Time.current
      )
      identity.source_identity_keys.create!(workspace: record.workspace, kind: :domain, normalized_value: domain)
      identity
    end
end
