require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "normalizes email addresses" do
    user = User.new(email_address: "  NEW@Example.COM  ")

    assert_predicate user, :valid?
    assert_equal "new@example.com", user.email_address
  end

  test "requires a case-insensitively unique email address" do
    user = User.new(email_address: users(:owner).email_address.upcase)

    assert_not user.valid?
    assert_includes user.errors[:email_address], "has already been taken"
  end
end
