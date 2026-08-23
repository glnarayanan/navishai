require "test_helper"

class AccountTest < ActiveSupport::TestCase
  test "requires a bounded name" do
    account = Account.new(workspace: workspaces(:acme_support), name: " ")

    assert_not account.valid?
    assert_includes account.errors[:name], "can't be blank"
  end

  test "an unmerged account is its own canonical record" do
    assert_equal accounts(:acme), accounts(:acme).canonical
  end
end
