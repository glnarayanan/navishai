require "test_helper"

class SupportQualityControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:acme_support)
  end

  test "owner member and viewer can read the quality page and navigation" do
    member = @workspace.memberships.create!(
      user: User.create!(email_address: "quality-member@example.com", password: "password12345", verified_at: Time.current),
      role: :member
    )
    viewer = @workspace.memberships.create!(
      user: User.create!(email_address: "quality-viewer@example.com", password: "password12345", verified_at: Time.current),
      role: :viewer
    )

    [ users(:owner), member.user, viewer.user ].each do |user|
      sign_in_as user
      get workspace_support_quality_path(@workspace)

      assert_response :success
      assert_select "h1", "Support quality"
      assert_select ".nav-label", "Quality"
      assert_select "[data-metric=open_cases] strong", "0"
      sign_out
    end
  end

  test "foreign Workspace paths fail closed" do
    sign_in_as users(:owner)

    get workspace_support_quality_path(workspaces(:beta_support))

    assert_response :not_found
  end
end
