require "test_helper"

class KnowledgeImprovementCandidatesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
  end

  test "writers create a candidate from a blocked draft and managers assign it" do
    support_case = create_support_case(subject: "Quality blocked draft")
    artifact = create_draft_artifact(
      workspace: @workspace, support_case:, membership: @owner,
      body: "Blocked without a current policy.", result_state: "blocked",
      blocker_message: "Applicable knowledge is missing."
    )
    manager = @workspace.memberships.create!(
      user: User.create!(email_address: "candidate-manager@example.com", password: "password12345", verified_at: Time.current),
      role: :manager
    )
    sign_in_as users(:owner)

    post workspace_knowledge_improvement_candidates_path(@workspace), params: {
      crew_artifact_id: artifact.id, return_to: "quality"
    }

    assert_redirected_to workspace_support_quality_path(@workspace)
    assert_equal "Knowledge improvement candidate recorded from the blocked draft.", flash[:notice]
    candidate = @workspace.knowledge_improvement_candidates.find_by!(source_crew_artifact: artifact)

    post assign_workspace_knowledge_improvement_candidate_path(@workspace, candidate), params: {
      assigned_to_membership_id: manager.id
    }

    assert_redirected_to workspace_knowledge_improvements_path(@workspace)
    assert_equal manager, candidate.reload.assigned_to_membership
    follow_redirect!
    assert_select "[data-metric=candidates] strong", "1"
    assert_select ".improvement-candidate", text: /Quality blocked draft/
  end

  test "viewers cannot create or assign candidates" do
    support_case = create_support_case(subject: "Viewer blocked draft")
    artifact = create_draft_artifact(
      workspace: @workspace, support_case:, membership: @owner,
      body: "Blocked draft.", result_state: "blocked"
    )
    candidate = KnowledgeImprovementWorkflow.create_from_blocked_draft!(
      workspace: @workspace, membership: @owner, artifact:
    )
    viewer = @workspace.memberships.create!(
      user: User.create!(email_address: "candidate-viewer@example.com", password: "password12345", verified_at: Time.current),
      role: :viewer
    )
    sign_in_as viewer.user

    post workspace_knowledge_improvement_candidates_path(@workspace), params: { crew_artifact_id: artifact.id }
    assert_response :forbidden

    post assign_workspace_knowledge_improvement_candidate_path(@workspace, candidate), params: {
      assigned_to_membership_id: @owner.id
    }
    assert_response :forbidden
  end

  test "foreign Workspace paths fail closed" do
    sign_in_as users(:owner)

    post workspace_knowledge_improvement_candidates_path(workspaces(:beta_support)), params: { knowledge_source_id: 1 }

    assert_response :not_found
  end
end
