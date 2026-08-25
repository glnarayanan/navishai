require "test_helper"

class MembershipTest < ActiveSupport::TestCase
  test "allows one membership per user and workspace" do
    membership = Membership.new(workspace: workspaces(:acme_support), user: users(:owner))

    assert_not membership.valid?
    assert_includes membership.errors[:user_id], "has already been taken"
  end
end
