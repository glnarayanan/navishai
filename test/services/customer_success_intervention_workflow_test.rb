require "test_helper"

class CustomerSuccessInterventionWorkflowTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
    @account = accounts(:acme)
    @at = Time.current.change(usec: 0)
    @assessment = AccountHealth.recalculate!(
      workspace: @workspace, account: @account, trigger_kind: "human_request",
      membership: @owner, at: @at
    )
    @plan, @success_review = create_reviewed_intervention_plan(
      workspace: @workspace, account: @account, membership: @owner, assessment: @assessment
    )
  end

  test "freezes a human-owned intervention and an association-only observed outcome" do
    proposed_at = @at + 1.minute
    intervention = propose_test_intervention(
      workspace: @workspace, account: @account, membership: @owner,
      assessment: @assessment, artifact: @plan, at: proposed_at
    )

    assert intervention.proposed?
    assert_equal @owner, intervention.accountable_membership
    assert_equal @plan.citations, intervention.supporting_evidence
    assert_equal proposed_at, intervention.proposed_at
    assert_equal "complete", intervention.proposing_crew_artifact.contract_result_state

    approved_at = proposed_at + 1.minute
    CustomerSuccessInterventionWorkflow.approve!(
      workspace: @workspace, membership: @owner, intervention:, at: approved_at
    )
    completed_at = approved_at + 1.minute
    CustomerSuccessInterventionWorkflow.complete!(
      workspace: @workspace, membership: @owner, intervention:, at: completed_at
    )
    before_attributes = @assessment.attributes
    before_signals = @assessment.signals.order(:id).map(&:attributes)
    after_assessment = AccountHealth.recalculate!(
      workspace: @workspace, account: @account, trigger_kind: "human_request",
      membership: @owner, at: completed_at + 1.minute
    )
    review = CustomerSuccessInterventionWorkflow.review!(
      workspace: @workspace, membership: @owner, intervention:,
      after_assessment:, uncertainty: "Timing alone cannot establish cause.", at: completed_at + 2.minutes
    )

    assert intervention.reload.reviewed?
    assert_equal @owner, intervention.approved_by_membership
    assert_equal @owner, intervention.completed_by_membership
    assert_equal @assessment.id, review.before_snapshot.fetch("assessment_id")
    assert_equal after_assessment.id, review.after_snapshot.fetch("assessment_id")
    assert_equal @assessment.score, review.before_snapshot.fetch("score")
    assert_equal after_assessment.score, review.after_snapshot.fetch("score")
    assert_equal before_attributes, @assessment.reload.attributes
    assert_equal before_signals, @assessment.signals.reload.order(:id).map(&:attributes)
    assert_operator review.before_snapshot.fetch("signals").size, :<=,
      CustomerSuccessInterventionWorkflow::MAX_SNAPSHOT_SIGNALS
    assert_includes review.observed_association, "association only"
    assert_includes review.observed_association, "does not assign cause"
    assert_equal %w[
      account.intervention_proposed account.intervention_approved account.intervention_completed
      account.intervention_reviewed
    ], @workspace.audit_events.where(
      subject_type: "CustomerSuccessIntervention", subject_id: intervention.id
    ).order(:id).pluck(:action)
  end

  test "permits only Managers to decide and only the accountable writable human to complete" do
    manager = create_membership("intervention-manager", :manager)
    member = create_membership("intervention-member", :member)
    other_member = create_membership("intervention-other", :member)
    viewer = create_membership("intervention-viewer", :viewer)
    intervention = propose_test_intervention(
      workspace: @workspace, account: @account, membership: @owner,
      accountable_membership: member, assessment: @assessment, artifact: @plan, at: @at + 1.minute
    )

    assert_raises(Current::RoleAccessDenied) do
      CustomerSuccessInterventionWorkflow.approve!(
        workspace: @workspace, membership: member, intervention:
      )
    end
    CustomerSuccessInterventionWorkflow.approve!(
      workspace: @workspace, membership: manager, intervention:, at: @at + 2.minutes
    )
    assert_raises(Current::RoleAccessDenied) do
      CustomerSuccessInterventionWorkflow.complete!(
        workspace: @workspace, membership: other_member, intervention:
      )
    end
    CustomerSuccessInterventionWorkflow.complete!(
      workspace: @workspace, membership: member, intervention:, at: @at + 3.minutes
    )
    assert_equal member, intervention.reload.completed_by_membership

    second_plan, = create_reviewed_intervention_plan(
      workspace: @workspace, account: @account, membership: @owner, assessment: @assessment
    )
    assert_raises(Current::RoleAccessDenied) do
      propose_test_intervention(
        workspace: @workspace, account: @account, membership: viewer,
        assessment: @assessment, artifact: second_plan, at: @at + 1.minute
      )
    end
  end

  test "supports human abandonment before or after approval and rejects terminal changes" do
    proposed = propose_test_intervention(
      workspace: @workspace, account: @account, membership: @owner,
      assessment: @assessment, artifact: @plan, at: @at + 1.minute
    )
    CustomerSuccessInterventionWorkflow.abandon!(
      workspace: @workspace, membership: @owner, intervention: proposed,
      reason: "The Account owner chose a different response.", at: @at + 2.minutes
    )
    assert proposed.reload.abandoned?
    assert_nil proposed.approved_by_membership
    assert_raises(CustomerSuccessInterventionWorkflow::InvalidCommand) do
      CustomerSuccessInterventionWorkflow.approve!(
        workspace: @workspace, membership: @owner, intervention: proposed
      )
    end

    second_plan, = create_reviewed_intervention_plan(
      workspace: @workspace, account: @account, membership: @owner, assessment: @assessment
    )
    approved = propose_test_intervention(
      workspace: @workspace, account: @account, membership: @owner,
      assessment: @assessment, artifact: second_plan, at: @at + 1.minute
    )
    CustomerSuccessInterventionWorkflow.approve!(
      workspace: @workspace, membership: @owner, intervention: approved, at: @at + 2.minutes
    )
    CustomerSuccessInterventionWorkflow.abandon!(
      workspace: @workspace, membership: @owner, intervention: approved,
      reason: "The approved work is no longer relevant.", at: @at + 3.minutes
    )
    assert approved.reload.abandoned?
    assert_equal @owner, approved.approved_by_membership
  end

  test "rejects unreviewed blocked changed and superseded AI proposals" do
    wrong_kind = create_intervention_artifact(
      workspace: @workspace, account: @account, membership: @owner, assessment: @assessment,
      kind: "risk_investigation"
    )
    blocked_plan, = create_reviewed_intervention_plan(
      workspace: @workspace, account: @account, membership: @owner, assessment: @assessment,
      plan_result: "blocked"
    )
    changed_plan, = create_reviewed_intervention_plan(
      workspace: @workspace, account: @account, membership: @owner, assessment: @assessment,
      review_outcome: "changes_requested"
    )
    create_intervention_artifact(
      workspace: @workspace, account: @account, membership: @owner, assessment: @assessment,
      kind: "intervention_plan", supersedes: @plan
    )

    [ wrong_kind, blocked_plan, changed_plan, @plan ].each do |artifact|
      error = assert_raises(CustomerSuccessInterventionWorkflow::InvalidCommand) do
        propose_test_intervention(
          workspace: @workspace, account: @account, membership: @owner,
          assessment: @assessment, artifact:, at: @at + 1.minute
        )
      end
      assert_match(/intervention plan|success review/i, error.message)
    end
  end

  test "rejects foreign scope unbounded content and past follow-up dates" do
    beta = workspaces(:beta_support)
    assert_raises(ActiveRecord::RecordNotFound) do
      CustomerSuccessInterventionWorkflow.propose!(
        workspace: beta, membership: memberships(:outsider_beta), account: @account,
        assessment: @assessment, artifact: @plan, accountable_membership: memberships(:outsider_beta),
        expected_observable_change: "Foreign", target_on: @at.to_date + 1.day,
        reason: "Foreign", at: @at
      )
    end
    assert_raises(CustomerSuccessInterventionWorkflow::InvalidCommand) do
      CustomerSuccessInterventionWorkflow.propose!(
        workspace: @workspace, membership: @owner, account: @account,
        assessment: @assessment, artifact: @plan, accountable_membership: @owner,
        expected_observable_change: "x" * 2_001, target_on: @at.to_date + 1.day,
        reason: "Bounded", at: @at
      )
    end
    error = assert_raises(CustomerSuccessInterventionWorkflow::InvalidCommand) do
      CustomerSuccessInterventionWorkflow.propose!(
        workspace: @workspace, membership: @owner, account: @account,
        assessment: @assessment, artifact: @plan, accountable_membership: @owner,
        expected_observable_change: "Observable", target_on: @at.to_date - 1.day,
        reason: "Bounded", at: @at
      )
    end
    assert_equal "Follow-up date cannot be before the proposal date.", error.message
  end

  test "rejects a plan that does not cite the selected originating assessment" do
    newer_assessment = AccountHealth.recalculate!(
      workspace: @workspace, account: @account, trigger_kind: "human_request",
      membership: @owner, at: @at + 1.minute
    )

    error = assert_raises(CustomerSuccessInterventionWorkflow::InvalidCommand) do
      propose_test_intervention(
        workspace: @workspace, account: @account, membership: @owner,
        assessment: newer_assessment, artifact: @plan, at: @at + 2.minutes
      )
    end
    assert_equal "The intervention plan must cite the originating deterministic assessment.", error.message
  end

  test "database guards immutable provenance transitions reviews and truncation" do
    intervention = propose_test_intervention(
      workspace: @workspace, account: @account, membership: @owner,
      assessment: @assessment, artifact: @plan, at: @at + 1.minute
    )
    assert_statement_rejected do
      CustomerSuccessIntervention.where(id: intervention.id).update_all(reason: "Rewrite history")
    end
    assert_statement_rejected do
      CustomerSuccessIntervention.where(id: intervention.id).update_all(status: "reviewed")
    end
    assert_statement_rejected { CustomerSuccessIntervention.where(id: intervention.id).delete_all }

    CustomerSuccessInterventionWorkflow.approve!(
      workspace: @workspace, membership: @owner, intervention:, at: @at + 2.minutes
    )
    other = create_membership("intervention-provenance", :manager)
    assert_statement_rejected do
      CustomerSuccessIntervention.where(id: intervention.id).update_all(
        status: "completed", approved_by_membership_id: other.id,
        completed_by_membership_id: @owner.id, completed_at: @at + 3.minutes
      )
    end
    CustomerSuccessInterventionWorkflow.complete!(
      workspace: @workspace, membership: @owner, intervention:, at: @at + 3.minutes
    )
    assert_statement_rejected do
      CustomerSuccessIntervention.where(id: intervention.id).update_all(status: "reviewed")
    end

    after_assessment = AccountHealth.recalculate!(
      workspace: @workspace, account: @account, trigger_kind: "human_request",
      membership: @owner, at: @at + 4.minutes
    )
    review = CustomerSuccessInterventionWorkflow.review!(
      workspace: @workspace, membership: @owner, intervention:, after_assessment:,
      uncertainty: "Causality is not known.", at: @at + 5.minutes
    )
    assert_statement_rejected do
      CustomerSuccessInterventionOutcomeReview.where(id: review.id).update_all(uncertainty: "Rewrite")
    end
    assert_statement_rejected do
      CustomerSuccessInterventionOutcomeReview.where(id: review.id).delete_all
    end
    assert_statement_rejected do
      CustomerSuccessInterventionOutcomeReview.connection.execute(
        "TRUNCATE customer_success_intervention_outcome_reviews"
      )
    end
  end

  test "retention redacts text and snapshots once while preserving lineage and actors" do
    intervention = propose_test_intervention(
      workspace: @workspace, account: @account, membership: @owner,
      assessment: @assessment, artifact: @plan, at: @at + 1.minute
    )
    CustomerSuccessInterventionWorkflow.approve!(
      workspace: @workspace, membership: @owner, intervention:, at: @at + 2.minutes
    )
    CustomerSuccessInterventionWorkflow.complete!(
      workspace: @workspace, membership: @owner, intervention:, at: @at + 3.minutes
    )
    after_assessment = AccountHealth.recalculate!(
      workspace: @workspace, account: @account, trigger_kind: "human_request",
      membership: @owner, at: @at + 4.minutes
    )
    review = CustomerSuccessInterventionWorkflow.review!(
      workspace: @workspace, membership: @owner, intervention:, after_assessment:,
      uncertainty: "Private uncertainty", at: @at + 5.minutes
    )
    lineage = intervention.reload.attributes.slice(
      "account_id", "account_health_assessment_id", "proposing_crew_artifact_id",
      "accountable_membership_id", "proposed_by_membership_id", "approved_by_membership_id",
      "completed_by_membership_id", "status"
    )

    expire_content(@workspace, @at + 1.day)
    intervention.reload
    review.reload
    assert_equal "[Expired by retention policy]", intervention.expected_observable_change
    assert_equal "[Expired by retention policy]", intervention.reason
    assert_equal "[Expired by retention policy]", intervention.supporting_evidence.sole.fetch("label")
    assert_equal lineage, intervention.attributes.slice(*lineage.keys)
    assert review.retention_expired?
    assert_equal @assessment, review.before_account_health_assessment
    assert_equal after_assessment, review.after_account_health_assessment
    assert_equal @owner, review.reviewed_by_membership

    intervention_marker = intervention.updated_at
    review_marker = review.updated_at
    expire_content(@workspace, @at + 1.day)
    assert_equal intervention_marker, intervention.reload.updated_at
    assert_equal review_marker, review.reload.updated_at
    assert_statement_rejected do
      CustomerSuccessIntervention.where(id: intervention.id).update_all(reason: "Restore private text")
    end
  end

  private
    def create_membership(prefix, role)
      user = User.create!(
        email_address: "#{prefix}-#{SecureRandom.hex(3)}@example.com",
        password: "password12345", verified_at: Time.current
      )
      @workspace.memberships.create!(user:, role:)
    end

    def assert_statement_rejected(&block)
      assert_raises(ActiveRecord::StatementInvalid) do
        ActiveRecord::Base.transaction(requires_new: true, &block)
      end
    end

    def expire_content(workspace, cutoff)
      connection = ActiveRecord::Base.connection
      connection.execute("SET CONSTRAINTS ALL IMMEDIATE")
      connection.select_value(
        "SELECT expire_workspace_content(#{connection.quote(workspace.id)}, #{connection.quote(cutoff)})"
      )
    end
end
