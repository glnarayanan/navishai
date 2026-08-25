require "test_helper"

class MembershipTest < ActiveSupport::TestCase
  test "allows one membership per user and workspace" do
    membership = Membership.new(workspace: workspaces(:acme_support), user: users(:owner))

    assert_not membership.valid?
    assert_includes membership.errors[:user_id], "has already been taken"
  end

  test "defines the five workspace roles" do
    assert_equal %w[owner admin manager member viewer], Membership::ROLES
  end

  test "admin can invite operational roles but not admins or owners" do
    membership = Membership.new(role: :admin)

    assert membership.can_invite_role?(:manager)
    assert membership.can_invite_role?(:member)
    assert membership.can_invite_role?(:viewer)
    assert_not membership.can_invite_role?(:admin)
    assert_not membership.can_invite_role?(:owner)
  end

  test "viewer cannot write or manage work" do
    membership = Membership.new(role: :viewer)

    assert_not membership.can_write?
    assert_not membership.can_manage_work?
  end

  test "does not destroy the last owner" do
    membership = memberships(:owner_support)

    assert_not membership.destroy
    assert_includes membership.errors[:base], "Workspace must retain at least one Owner"
  end

  test "allows an owner to leave when another owner remains" do
    Membership.create!(workspace: workspaces(:acme_support), user: users(:teammate), role: :owner)

    assert memberships(:owner_support).destroy
  end
end
