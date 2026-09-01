require "test_helper"

class WorkspacesControllerTest < ActionDispatch::IntegrationTest
  test "lists only the signed-in user's workspaces" do
    sign_in_as users(:owner)

    get workspaces_path

    assert_response :success
    assert_select "a strong", text: workspaces(:acme_support).name
    assert_select "a strong", text: workspaces(:beta_support).name, count: 0
  end

  test "returns not found for another workspace" do
    sign_in_as users(:owner)

    get workspace_path(workspaces(:beta_support))

    assert_response :not_found
  end

  test "an Owner creates a sibling workspace with defaults and an audit trail" do
    sign_in_as users(:owner)

    assert_difference [ "Workspace.count", "Membership.count", "AuditEvent.count" ], 1 do
      post workspaces_path, params: { workspace: {
        organization_id: organizations(:acme).id,
        name: "Acme Onboarding",
        slug: "onboarding"
      } }
    end

    workspace = Workspace.find_by!(name: "Acme Onboarding")
    assert_redirected_to edit_workspace_path(workspace)
    assert_equal organizations(:acme), workspace.organization
    assert_equal users(:owner), workspace.memberships.sole.user
    assert workspace.memberships.sole.owner?
    assert workspace.crew_templates.exists?
    assert workspace.resolution_contract_families.exists?
    assert workspace.health_scorecard
    assert workspace.workspace_data_policy
    assert AuditEvent.where(action: "workspace.created", workspace:, actor: users(:owner), subject_id: workspace.id).exists?
  end

  test "workspace creation is limited to organisations the user owns" do
    sign_in_as users(:owner)

    assert_no_difference [ "Workspace.count", "Membership.count", "AuditEvent.count" ] do
      post workspaces_path, params: { workspace: {
        organization_id: organizations(:beta).id,
        name: "Foreign workspace",
        slug: "foreign"
      } }
    end

    assert_response :forbidden
  end

  test "a non-Owner cannot create or edit a workspace" do
    sign_in_as users(:teammate)

    get new_workspace_path
    assert_response :forbidden

    get edit_workspace_path(workspaces(:acme_success))
    assert_response :forbidden

    patch workspace_path(workspaces(:acme_success)), params: { workspace: { name: "Changed", slug: "changed" } }
    assert_response :forbidden
    assert_equal "Acme Success", workspaces(:acme_success).reload.name
  end

  test "an Owner updates workspace identity with an audit trail" do
    workspace = workspaces(:acme_support)
    sign_in_as users(:owner)

    assert_difference "AuditEvent.count", 1 do
      patch workspace_path(workspace), params: { workspace: { name: "Acme Care", slug: "care" } }
    end

    assert_redirected_to edit_workspace_path(workspace)
    assert_equal [ "Acme Care", "care" ], workspace.reload.values_at(:name, :slug)
    event = AuditEvent.order(:id).last
    assert_equal "workspace.updated", event.action
    assert_equal({
      "previous_name" => "Acme Support", "previous_slug" => "support",
      "name" => "Acme Care", "slug" => "care"
    }, event.metadata)
  end

  test "workspace identity update rolls back when its audit fails" do
    workspace = workspaces(:acme_support)
    sign_in_as users(:owner)
    original_record = AuditEvent.method(:record!)
    AuditEvent.define_singleton_method(:record!) { |**| raise "audit unavailable" }

    begin
      assert_raises(RuntimeError) do
        patch workspace_path(workspace), params: { workspace: { name: "Acme Care", slug: "care" } }
      end
    ensure
      AuditEvent.define_singleton_method(:record!, original_record)
    end

    assert_equal [ "Acme Support", "support" ], workspace.reload.values_at(:name, :slug)
  end

  test "invalid workspace creation returns errors without partial records" do
    sign_in_as users(:owner)

    assert_no_difference [ "Workspace.count", "Membership.count", "AuditEvent.count" ] do
      post workspaces_path, params: { workspace: {
        organization_id: organizations(:acme).id,
        name: "",
        slug: "Not valid"
      } }
    end

    assert_response :unprocessable_content
    assert_select "[role='alert']"
  end
end
