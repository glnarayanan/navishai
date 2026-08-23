require "test_helper"

class ContactTest < ActiveSupport::TestCase
  test "rejects an account from another workspace" do
    contact = Contact.new(
      workspace: workspaces(:acme_support),
      account: accounts(:beta),
      name: "Cross tenant"
    )

    assert_not contact.valid?
    assert_includes contact.errors[:account], "must belong to the same workspace"
  end

  test "database rejects an account from another workspace" do
    assert_raises(ActiveRecord::StatementInvalid) do
      contacts(:alice).update_columns(account_id: accounts(:beta).id)
    end
  end
end
