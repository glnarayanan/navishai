require "test_helper"

class CrewTasksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
    CrewConfiguration.install_defaults!(workspace: @workspace)
    @support_case = create_support_case
    @profile = @workspace.agent_profiles.find_by!(role_key: "support_coordinator")
    sign_in_as @owner.user
  end

  test "case crew workspace creates and advances an attributable task" do
    get workspace_support_case_crew_tasks_path(@workspace, @support_case)
    assert_response :success
    assert_select "h1", "Crew work"
    assert_select ".crew-progress dd", text: "0", count: 3

    assert_difference [ "CrewTask.count", "CrewTaskEvent.count" ], 1 do
      post workspace_support_case_crew_tasks_path(@workspace, @support_case), params: {
        title: "Investigate access failure",
        input_context: "Use the current case conversation.",
        expected_output: "Find the cause, cite the case record, and state uncertainty.",
        agent_profile_id: @profile.id
      }
    end
    task = @support_case.crew_tasks.find_by!(title: "Investigate access failure")
    assert_redirected_to workspace_support_case_crew_task_path(@workspace, @support_case, task)

    assert_difference "CrewTaskEvent.count", 1 do
      post command_workspace_support_case_crew_task_path(@workspace, @support_case, task), params: {
        command_name: "start", expected_sequence: task.current_event.sequence_number
      }
    end
    assert_redirected_to workspace_support_case_crew_task_path(@workspace, @support_case, task)
    assert task.reload.in_progress?

    get workspace_support_case_crew_task_path(@workspace, @support_case, task)
    assert_response :success
    assert_select "h1", "Investigate access failure"
    assert_select ".crew-event-list li", count: 2
    assert_select ".crew-task-actions", text: /Coordinator \/ Triage/
  end

  test "invalid and stale commands rerender without changing durable work" do
    post workspace_support_case_crew_tasks_path(@workspace, @support_case), params: {
      title: " ", input_context: " ", expected_output: " ", agent_profile_id: @profile.id
    }
    assert_response :unprocessable_content
    assert_select ".inline-error", text: /Title can't be blank/

    task = CrewWork.create!(workspace: @workspace, membership: @owner, scope: @support_case,
      profile: @profile, title: "Current task", input_context: "Use current case facts.",
      expected_output: "Produce an evidence-backed result.")
    old_sequence = task.current_event.sequence_number
    CrewWork.apply!(workspace: @workspace, membership: @owner, task:, command: :start,
      expected_sequence: old_sequence)

    assert_no_difference "CrewTaskEvent.count" do
      post command_workspace_support_case_crew_task_path(@workspace, @support_case, task), params: {
        command_name: "comment", expected_sequence: old_sequence, body: "Stale note"
      }
    end
    assert_response :unprocessable_content
    assert_select ".inline-error", text: /changed after the page loaded/
  end

  test "viewer reads but cannot write and foreign paths fail closed" do
    task = CrewWork.create!(workspace: @workspace, membership: @owner, scope: @support_case,
      profile: @profile, title: "Visible task", input_context: "Use current case facts.",
      expected_output: "Keep work visible.")
    viewer_user = User.create!(email_address: "crew-ui-viewer@example.com", password: "password12345", verified_at: Time.current)
    @workspace.memberships.create!(user: viewer_user, role: :viewer)
    sign_in_as viewer_user

    get workspace_support_case_crew_task_path(@workspace, @support_case, task)
    assert_response :success
    assert_select ".read-only-notice", text: /Read-only access/
    assert_select ".crew-command-form", count: 0

    assert_no_difference [ "CrewTask.count", "CrewTaskEvent.count" ] do
      post workspace_support_case_crew_tasks_path(@workspace, @support_case), params: {
        title: "Forged", input_context: "Denied", expected_output: "Denied", agent_profile_id: @profile.id
      }
    end
    assert_response :forbidden

    foreign_case = create_support_case(
      workspace: workspaces(:beta_support), contact: contacts(:bob), membership: memberships(:outsider_beta)
    )
    get workspace_support_case_crew_tasks_path(@workspace, foreign_case)
    assert_response :not_found
  end
end
