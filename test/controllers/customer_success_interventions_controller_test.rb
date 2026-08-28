require "test_helper"

class CustomerSuccessInterventionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
    @account = accounts(:acme)
    @at = Time.current.change(usec: 0)
    @assessment = AccountHealth.recalculate!(
      workspace: @workspace, account: @account, trigger_kind: "human_request",
      membership: @owner, at: @at
    )
    @plan, = create_reviewed_intervention_plan(
      workspace: @workspace, account: @account, membership: @owner, assessment: @assessment
    )
    sign_in_as @owner.user
  end

  test "owner adopts approves completes and reviews a proposal without a communication action" do
    get workspace_account_path(@workspace, @account)
    assert_response :success
    assert_select "#customer-success-interventions h2", text: "Interventions and observed outcomes"
    assert_select ".intervention-proposal", count: 1
    assert_select "form[action=?]", workspace_account_interventions_path(@workspace, @account), count: 1
    assert_select "#customer-success-interventions", text: /Nothing here sends or schedules customer communication/

    assert_difference [ "CustomerSuccessIntervention.count", "AuditEvent.count" ], 1 do
      post workspace_account_interventions_path(@workspace, @account), params: {
        proposing_crew_artifact_id: @plan.id,
        account_health_assessment_id: @assessment.id,
        expected_observable_change: "Raise the next deterministic health score.",
        target_on: Date.current + 7.days,
        reason: "The human Account owner accepted this reviewed plan."
      }
    end
    intervention = @workspace.customer_success_interventions.order(:id).last
    assert_redirected_to workspace_account_path(
      @workspace, @account, anchor: "customer-success-interventions"
    )

    post approve_workspace_account_intervention_path(@workspace, @account, intervention)
    assert_redirected_to workspace_account_path(
      @workspace, @account, anchor: "customer-success-interventions"
    )
    post complete_workspace_account_intervention_path(@workspace, @account, intervention)
    assert_redirected_to workspace_account_path(
      @workspace, @account, anchor: "customer-success-interventions"
    )
    completed_at = intervention.reload.completed_at
    after_assessment = AccountHealth.recalculate!(
      workspace: @workspace, account: @account, trigger_kind: "human_request",
      membership: @owner, at: completed_at + 1.minute
    )
    post review_workspace_account_intervention_path(@workspace, @account, intervention), params: {
      after_account_health_assessment_id: after_assessment.id,
      uncertainty: "The time sequence does not establish causation."
    }
    assert_redirected_to workspace_account_path(
      @workspace, @account, anchor: "customer-success-interventions"
    )
    assert intervention.reload.reviewed?

    get workspace_account_path(@workspace, @account)
    assert_response :success
    assert_select ".intervention-card", count: 1
    assert_select ".intervention-layers > section", count: 3
    assert_select ".intervention-outcome", text: /association only; it does not assign cause/
    assert_select "form[action=?]", workspace_account_interventions_path(@workspace, @account), count: 0
  end

  test "Manager decides Member completes and Viewer receives no write control" do
    manager = create_membership("controller-intervention-manager", :manager)
    member = create_membership("controller-intervention-member", :member)
    viewer = create_membership("controller-intervention-viewer", :viewer)
    intervention = propose_test_intervention(
      workspace: @workspace, account: @account, membership: @owner,
      accountable_membership: member, assessment: @assessment, artifact: @plan, at: @at + 1.minute
    )

    sign_in_as member.user
    post approve_workspace_account_intervention_path(@workspace, @account, intervention)
    assert_response :forbidden
    assert intervention.reload.proposed?

    sign_in_as manager.user
    post approve_workspace_account_intervention_path(@workspace, @account, intervention)
    assert_redirected_to workspace_account_path(
      @workspace, @account, anchor: "customer-success-interventions"
    )

    sign_in_as member.user
    post complete_workspace_account_intervention_path(@workspace, @account, intervention)
    assert_redirected_to workspace_account_path(
      @workspace, @account, anchor: "customer-success-interventions"
    )
    assert_equal member, intervention.reload.completed_by_membership

    second_plan, = create_reviewed_intervention_plan(
      workspace: @workspace, account: @account, membership: @owner, assessment: @assessment
    )
    sign_in_as viewer.user
    get workspace_account_path(@workspace, @account)
    assert_response :success
    assert_select "form[action=?]", workspace_account_interventions_path(@workspace, @account), count: 0
    assert_select "form[action=?]", review_workspace_account_intervention_path(
      @workspace, @account, intervention
    ), count: 0
    post workspace_account_interventions_path(@workspace, @account), params: {
      proposing_crew_artifact_id: second_plan.id,
      account_health_assessment_id: @assessment.id,
      expected_observable_change: "Viewer cannot own this.",
      target_on: Date.current + 7.days, reason: "Denied"
    }
    assert_response :forbidden
  end

  test "commands reject another Account Workspace stale proposal and invalid transition" do
    other_account = @workspace.accounts.create!(name: "Intervention scope check")
    intervention = propose_test_intervention(
      workspace: @workspace, account: @account, membership: @owner,
      assessment: @assessment, artifact: @plan, at: @at + 1.minute
    )

    post approve_workspace_account_intervention_path(@workspace, other_account, intervention)
    assert_response :not_found
    post approve_workspace_account_intervention_path(
      workspaces(:beta_support), accounts(:beta), intervention
    )
    assert_response :not_found

    post workspace_account_interventions_path(@workspace, @account), params: {
      proposing_crew_artifact_id: @plan.id,
      account_health_assessment_id: @assessment.id,
      expected_observable_change: "Duplicate", target_on: Date.current + 7.days, reason: "Duplicate"
    }
    assert_redirected_to workspace_account_path(
      @workspace, @account, anchor: "customer-success-interventions"
    )
    assert_equal "This AI proposal already has an intervention record.", flash[:alert]

    post complete_workspace_account_intervention_path(@workspace, @account, intervention)
    assert_redirected_to workspace_account_path(
      @workspace, @account, anchor: "customer-success-interventions"
    )
    assert_equal "Only a approved intervention can be completed.", flash[:alert]
    assert intervention.reload.proposed?
  end

  private
    def create_membership(prefix, role)
      user = User.create!(
        email_address: "#{prefix}-#{SecureRandom.hex(3)}@example.com",
        password: "password12345", verified_at: Time.current
      )
      @workspace.memberships.create!(user:, role:)
    end
end
