require "test_helper"

class HealthScorecardsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
    sign_in_as @owner.user
  end

  test "guides an owner from proposal through preview and publish" do
    get workspace_health_scorecard_path(@workspace)
    assert_response :success
    assert_select "h1", "Health scorecard"
    assert_select "form[action=?]", propose_workspace_health_scorecard_path(@workspace)

    post propose_workspace_health_scorecard_path(@workspace), params: proposal_params
    version = @workspace.health_scorecard.versions.first
    assert_redirected_to workspace_health_scorecard_path(@workspace, version_id: version.id)

    post backtest_workspace_health_scorecard_path(@workspace), params: { version_id: version.id }
    assert_redirected_to workspace_health_scorecard_path(@workspace, version_id: version.id, anchor: "preview")
    post publish_workspace_health_scorecard_path(@workspace), params: {
      version_id: version.id, expected_current_version_id: @workspace.health_scorecard.current_version_id
    }
    assert_redirected_to workspace_health_scorecard_path(@workspace, version_id: version.id)
    assert_equal version, @workspace.health_scorecard.reload.current_version
  end

  test "renders invalid proposals and enforces writer and admin roles" do
    post propose_workspace_health_scorecard_path(@workspace), params: proposal_params.merge(healthy_min: 20)
    assert_response :unprocessable_content
    assert_select "[role=alert]", text: /bands must satisfy/

    manager = @workspace.memberships.create!(user: users(:teammate), role: :manager)
    sign_in_as manager.user
    post propose_workspace_health_scorecard_path(@workspace), params: proposal_params
    version = @workspace.health_scorecard.versions.first
    post backtest_workspace_health_scorecard_path(@workspace), params: { version_id: version.id }
    assert_redirected_to workspace_health_scorecard_path(@workspace, version_id: version.id, anchor: "preview")
    post publish_workspace_health_scorecard_path(@workspace), params: { version_id: version.id }
    assert_response :forbidden

    viewer = User.create!(email_address: "scorecard-viewer@example.com", password: "password12345", verified_at: Time.current)
    @workspace.memberships.create!(user: viewer, role: :viewer)
    sign_in_as viewer
    get workspace_health_scorecard_path(@workspace)
    assert_response :success
    assert_select ".scorecard-designer", count: 0
    post propose_workspace_health_scorecard_path(@workspace), params: proposal_params
    assert_response :forbidden
  end

  test "does not expose a foreign workspace version" do
    foreign = HealthScorecardDesigner.install_default!(workspace: workspaces(:beta_support)).current_version
    get workspace_health_scorecard_path(@workspace, version_id: foreign.id)
    assert_response :not_found
    post backtest_workspace_health_scorecard_path(@workspace), params: { version_id: foreign.id }
    assert_response :not_found
  end

  private
    def proposal_params
      {
        goal_prompt: "Focus the score on clear renewal risk.", healthy_min: 75, watch_min: 50,
        signals: {
          open_cases: { enabled: "1", weight: 30 },
          sla_breaches: { enabled: "0", weight: 25 }
        }
      }
    end
end
