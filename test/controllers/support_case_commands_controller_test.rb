require "test_helper"

class SupportCaseCommandsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:acme_support)
    @membership = memberships(:owner_support)
    @support_case = create_support_case
    add_inbound_message(@support_case)
    sign_in_as users(:owner)
  end

  test "commands update status, priority, assignment, tags, and notes" do
    assert_difference "SupportCaseStatusChange.count", 1 do
      patch transition_workspace_support_case_path(@workspace, @support_case), params: { status: "triaged", reason: "Initial review complete" }
    end
    assert_redirected_to workspace_support_case_path(@workspace, @support_case)
    assert_equal "triaged", @support_case.reload.status

    patch priority_workspace_support_case_path(@workspace, @support_case), params: { priority: "high" }
    patch assignment_workspace_support_case_path(@workspace, @support_case), params: { assigned_membership_id: @membership.id }
    tag = CaseWorkflow.create_tag!(workspace: @workspace, membership: @membership, name: "Access")
    post tag_workspace_support_case_path(@workspace, @support_case), params: { tag_id: tag.id }

    assert_difference "CaseNote.count", 1 do
      post notes_workspace_support_case_path(@workspace, @support_case), params: { body: "Check the identity provider logs." }
    end

    @support_case.reload
    assert_equal "high", @support_case.priority
    assert_equal @membership, @support_case.assigned_membership
    assert_includes @support_case.tags, tag
    assert_equal "Check the identity provider logs.", @support_case.case_notes.last.body
  end

  test "owner can unassign a case" do
    CaseWorkflow.assign!(
      workspace: @workspace, support_case: @support_case,
      membership: @membership, assignee: @membership
    )

    assert_difference -> { AuditEvent.where(action: "case.unassigned").count }, 1 do
      patch assignment_workspace_support_case_path(@workspace, @support_case), params: { assigned_membership_id: "" }
    end

    assert_redirected_to workspace_support_case_path(@workspace, @support_case)
    assert_nil @support_case.reload.assigned_membership
  end

  test "invalid and blank changes render inline errors and roll back" do
    assert_no_difference [ "SupportCaseStatusChange.count", "AuditEvent.count" ] do
      patch transition_workspace_support_case_path(@workspace, @support_case), params: { status: "closed", reason: "Skip the workflow" }
    end
    assert_response :unprocessable_content
    assert_select ".command-error[role='alert']", text: /cannot transition/
    assert_equal "new", @support_case.reload.status

    assert_no_difference [ "CaseNote.count", "AuditEvent.count" ] do
      post notes_workspace_support_case_path(@workspace, @support_case), params: { body: " " }
    end
    assert_response :unprocessable_content
    assert_select ".command-error[role='alert']"
  end

  test "duplicate tag creation rolls back definition and tagging" do
    CaseWorkflow.create_tag!(workspace: @workspace, membership: @membership, name: "Access")

    assert_no_difference [ "Tag.count", "SupportCaseTagging.count", "AuditEvent.count" ] do
      post create_tag_workspace_support_case_path(@workspace, @support_case), params: { name: "access" }
    end

    assert_response :unprocessable_content
    assert_select "input[name='name'][value='access']"
  end

  test "viewer forged writes are forbidden" do
    viewer = User.create!(email_address: "command-viewer@example.com", password: "password12345", verified_at: Time.current)
    Membership.create!(workspace: @workspace, user: viewer, role: :viewer)
    sign_in_as viewer

    assert_no_difference [ "SupportCaseStatusChange.count", "AuditEvent.count" ] do
      patch transition_workspace_support_case_path(@workspace, @support_case), params: { status: "triaged", reason: "Forged" }
    end

    assert_response :forbidden
    assert_select "h1", text: "You can’t change this case"
  end

  test "viewer cannot forge an unassignment" do
    CaseWorkflow.assign!(
      workspace: @workspace, support_case: @support_case,
      membership: @membership, assignee: @membership
    )
    viewer = User.create!(email_address: "unassign-viewer@example.com", password: "password12345", verified_at: Time.current)
    Membership.create!(workspace: @workspace, user: viewer, role: :viewer)
    sign_in_as viewer

    assert_no_difference [ "AuditEvent.count", "SupportCaseStatusChange.count" ] do
      patch assignment_workspace_support_case_path(@workspace, @support_case), params: { assigned_membership_id: "" }
    end

    assert_response :forbidden
    assert_equal @membership, @support_case.reload.assigned_membership
  end

  test "foreign case, tag, and assignee fail closed" do
    beta_case = create_support_case(
      workspace: workspaces(:beta_support), contact: contacts(:bob), membership: memberships(:outsider_beta)
    )
    patch priority_workspace_support_case_path(@workspace, beta_case), params: { priority: "high" }
    assert_response :not_found

    foreign_tag = Tag.create!(workspace: workspaces(:beta_support), name: "Foreign")
    post tag_workspace_support_case_path(@workspace, @support_case), params: { tag_id: foreign_tag.id }
    assert_response :not_found

    patch assignment_workspace_support_case_path(@workspace, @support_case), params: { assigned_membership_id: memberships(:outsider_beta).id }
    assert_response :not_found
  end
end
