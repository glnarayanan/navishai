require "test_helper"

class OrganizationTest < ActiveSupport::TestCase
  test "normalizes and validates its slug" do
    organization = Organization.new(name: "  New Org  ", slug: "  NEW-ORG  ")

    assert_predicate organization, :valid?
    assert_equal "New Org", organization.name
    assert_equal "new-org", organization.slug
  end

  test "requires a globally unique slug" do
    organization = Organization.new(name: "Other Acme", slug: organizations(:acme).slug)

    assert_not organization.valid?
    assert_includes organization.errors[:slug], "has already been taken"
  end
end
