require "test_helper"

class WorkspaceDeletionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:acme_support)
  end

  test "owner queues deletion with the exact workspace slug and loses access" do
    sign_in_as users(:owner)

    assert_enqueued_with job: WorkspaceDeletionJob do
      post workspace_deletion_path(@workspace), params: { confirmation: @workspace.slug }
    end

    assert_redirected_to workspaces_path
    assert @workspace.reload.deletion_requested?
    get workspace_support_cases_path(@workspace)
    assert_response :not_found

    get workspaces_path
    assert_response :success
    assert_select "h2", "Deletion in progress"
    assert_select "strong", @workspace.name
    assert_select "span", "Access blocked"
  end

  test "wrong confirmation and non-owner do not request deletion" do
    sign_in_as users(:owner)

    assert_no_difference "WorkspaceDeletionRequest.count" do
      post workspace_deletion_path(@workspace), params: { confirmation: "wrong" }
    end
    assert_redirected_to workspace_data_controls_path(@workspace)
    assert_nil @workspace.reload.deletion_requested_at

    sign_out
    membership = @workspace.memberships.create!(user: users(:teammate), role: :manager)
    sign_in_as membership.user
    assert_no_difference "WorkspaceDeletionRequest.count" do
      post workspace_deletion_path(@workspace), params: { confirmation: @workspace.slug }
    end
    assert_response :forbidden
  end

  test "owner retries a failed request from the workspace list" do
    request = @workspace.create_workspace_deletion_request!(
      requested_by: users(:owner), status: :failed, attempt_count: 1, failure_code: "timeout_error",
      completed_at: Time.current
    )
    @workspace.update!(deletion_requested_at: Time.current)
    sign_in_as users(:owner)

    get workspaces_path
    assert_select "span", text: "Failed: Timeout error"
    assert_select "form[action='#{workspace_deletion_path(@workspace)}']"

    assert_enqueued_with job: WorkspaceDeletionJob do
      patch workspace_deletion_path(@workspace)
    end
    assert_redirected_to workspaces_path
    assert request.reload.pending?
  end
end
