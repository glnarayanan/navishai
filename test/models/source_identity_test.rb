require "test_helper"

class SourceIdentityTest < ActiveSupport::TestCase
  test "requires one target matching the entity kind once matched" do
    identity = source_identities(:alice_email)
    identity.account = accounts(:acme)

    assert_not identity.valid?
    assert_includes identity.errors[:base], "target does not match entity kind"
  end

  test "rejects a target from another workspace" do
    identity = source_identities(:alice_email)
    identity.contact = contacts(:bob)

    assert_not identity.valid?
    assert_includes identity.errors[:base], "target belongs to another workspace"
  end

  test "database rejects a target from another workspace" do
    assert_raises(ActiveRecord::StatementInvalid) do
      source_identities(:alice_email).update_columns(contact_id: contacts(:bob).id)
    end
  end

  test "source tuple is unique within a workspace but reusable across workspaces" do
    original = source_identities(:alice_email)
    duplicate = original.dup
    duplicate.source_record_id = original.source_record_id

    assert_not duplicate.valid?

    cross_workspace = original.dup
    cross_workspace.workspace = workspaces(:beta_support)
    cross_workspace.contact = contacts(:bob)
    assert cross_workspace.valid?
  end

  test "key replacement retains old values without matching them" do
    identity = source_identities(:alice_email)

    identity.replace_keys!(email: "alice.new@example.com")

    assert_equal 2, identity.source_identity_keys.count
    assert_equal "alice@example.com", identity.source_identity_keys.where.not(retired_at: nil).sole.normalized_value
    assert_equal "alice.new@example.com", identity.source_identity_keys.current.sole.normalized_value
  end
end
