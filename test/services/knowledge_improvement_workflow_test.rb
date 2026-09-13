require "test_helper"

class KnowledgeImprovementWorkflowTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
    @at = Time.current.change(usec: 0)
  end

  test "creates assigns and resolves a blocked-draft candidate against a current knowledge version" do
    support_case = create_support_case(subject: "Missing reset policy")
    artifact = create_draft_artifact(
      workspace: @workspace, support_case:, membership: @owner,
      body: "I cannot cite a current reset policy.", result_state: "blocked",
      blocker_message: "Applicable knowledge is missing."
    )
    manager = create_membership("knowledge-assignee", :manager)
    candidate = KnowledgeImprovementWorkflow.create_from_blocked_draft!(
      workspace: @workspace, membership: @owner, artifact:, at: @at
    )
    KnowledgeImprovementWorkflow.triage!(
      workspace: @workspace, membership: @owner, candidate:,
      note: "This needs a current reset-policy source.", at: @at + 1.minute
    )
    KnowledgeImprovementWorkflow.assign!(
      workspace: @workspace, membership: @owner, candidate:, assignee: manager, at: @at + 2.minutes
    )
    source = KnowledgeIngestion.create!(
      workspace: @workspace, membership: manager, source_kind: :manual,
      title: "Current reset policy", content: "Send a fresh reset link from the account owner."
    )
    resolved = KnowledgeImprovementWorkflow.resolve!(
      workspace: @workspace, membership: manager, candidate:, knowledge_source: source, at: @at + 3.minutes
    )

    assert resolved.resolved?
    assert_not resolved.open_work?
    assert_equal manager, resolved.assigned_to_membership
    assert_equal source, resolved.resolved_knowledge_source
    assert_equal source.current_version, resolved.resolved_knowledge_source_version
    assert_equal %w[
      knowledge.improvement_created knowledge.improvement_triaged knowledge.improvement_assigned
      knowledge.improvement_resolved
    ], @workspace.audit_events.where(
      subject_type: "KnowledgeImprovementCandidate", subject_id: candidate.id
    ).order(:id).pluck(:action)
  end

  test "rejects ineligible assignees viewers members and foreign workspaces" do
    support_case = create_support_case(subject: "Ineligible assignee draft")
    artifact = create_draft_artifact(
      workspace: @workspace, support_case:, membership: @owner,
      body: "Blocked without knowledge.", result_state: "blocked"
    )
    candidate = KnowledgeImprovementWorkflow.create_from_blocked_draft!(
      workspace: @workspace, membership: @owner, artifact:, at: @at
    )
    member = create_membership("knowledge-member", :member)
    viewer = create_membership("knowledge-viewer", :viewer)

    assert_raises(Current::RoleAccessDenied) do
      KnowledgeImprovementWorkflow.create_from_blocked_draft!(
        workspace: @workspace, membership: viewer, artifact:, at: @at
      )
    end
    error = assert_raises(KnowledgeImprovementWorkflow::InvalidCommand) do
      KnowledgeImprovementWorkflow.assign!(
        workspace: @workspace, membership: @owner, candidate:, assignee: viewer, at: @at + 1.minute
      )
    end
    assert_equal "Choose a human who can maintain knowledge.", error.message
    error = assert_raises(KnowledgeImprovementWorkflow::InvalidCommand) do
      KnowledgeImprovementWorkflow.assign!(
        workspace: @workspace, membership: @owner, candidate:, assignee: member, at: @at + 1.minute
      )
    end
    assert_equal "Choose a human who can maintain knowledge.", error.message
    assert_raises(Current::RoleAccessDenied) do
      KnowledgeImprovementWorkflow.assign!(
        workspace: @workspace, membership: member, candidate:, assignee: @owner, at: @at + 1.minute
      )
    end
    assert_raises(Current::RoleAccessDenied) do
      KnowledgeImprovementWorkflow.assign!(
        workspace: workspaces(:beta_support), membership: memberships(:outsider_beta),
        candidate:, assignee: memberships(:outsider_beta), at: @at + 1.minute
      )
    end
    beta_manager = workspaces(:beta_support).memberships.create!(user: users(:teammate), role: :manager)
    assert_raises(ActiveRecord::RecordNotFound) do
      KnowledgeImprovementWorkflow.assign!(
        workspace: workspaces(:beta_support), membership: beta_manager,
        candidate:, assignee: beta_manager, at: @at + 1.minute
      )
    end
  end

  test "dismisses an open candidate and rejects a second candidate for the same draft" do
    support_case = create_support_case(subject: "Dismissed draft")
    artifact = create_draft_artifact(
      workspace: @workspace, support_case:, membership: @owner,
      body: "Blocked draft to dismiss.", result_state: "blocked"
    )
    candidate = KnowledgeImprovementWorkflow.create_from_blocked_draft!(
      workspace: @workspace, membership: @owner, artifact:, at: @at
    )
    KnowledgeImprovementWorkflow.dismiss!(
      workspace: @workspace, membership: @owner, candidate:,
      reason: "The customer already has the current policy.", at: @at + 1.minute
    )

    assert candidate.reload.dismissed?
    error = assert_raises(KnowledgeImprovementWorkflow::InvalidCommand) do
      KnowledgeImprovementWorkflow.create_from_blocked_draft!(
        workspace: @workspace, membership: @owner, artifact:, at: @at + 2.minutes
      )
    end
    assert_equal "That improvement candidate already exists.", error.message
    error = assert_raises(KnowledgeImprovementWorkflow::InvalidCommand) do
      KnowledgeImprovementWorkflow.resolve!(
        workspace: @workspace, membership: @owner, candidate:,
        knowledge_source: create_manual("Too late", "Current policy"), at: @at + 3.minutes
      )
    end
    assert_equal "Assign the candidate before linking a knowledge version.", error.message
  end

  test "creates a source candidate and rejects stale versions at resolve" do
    source = create_manual("Expired recovery", "Legacy cancellation steps", expires_at: 1.minute.ago)
    candidate = KnowledgeImprovementWorkflow.create_from_source!(
      workspace: @workspace, membership: @owner, knowledge_source: source, at: @at
    )
    KnowledgeImprovementWorkflow.assign!(
      workspace: @workspace, membership: @owner, candidate:, assignee: @owner, at: @at + 1.minute
    )
    error = assert_raises(KnowledgeImprovementWorkflow::InvalidCommand) do
      KnowledgeImprovementWorkflow.resolve!(
        workspace: @workspace, membership: @owner, candidate:, knowledge_source: source, at: @at + 2.minutes
      )
    end
    assert_equal "Link a current authorised knowledge version.", error.message

    KnowledgeIngestion.update!(
      workspace: @workspace, membership: @owner, knowledge_source: source,
      content: "Use the current recovery link.", upload: nil, expires_at: nil
    )
    resolved = KnowledgeImprovementWorkflow.resolve!(
      workspace: @workspace, membership: @owner, candidate:, knowledge_source: source.reload, at: @at + 3.minutes
    )
    assert resolved.resolved?
    assert_equal 2, source.versions.size
    assert_equal source.current_version, resolved.resolved_knowledge_source_version
  end

  test "database guards provenance transitions and truncation" do
    support_case = create_support_case(subject: "Protected candidate")
    artifact = create_draft_artifact(
      workspace: @workspace, support_case:, membership: @owner,
      body: "Protected blocked draft.", result_state: "blocked"
    )
    candidate = KnowledgeImprovementWorkflow.create_from_blocked_draft!(
      workspace: @workspace, membership: @owner, artifact:, at: @at
    )
    assert_statement_rejected do
      KnowledgeImprovementCandidate.where(id: candidate.id).update_all(detail: "Rewrite history")
    end
    assert_statement_rejected do
      KnowledgeImprovementCandidate.where(id: candidate.id).update_all(status: "resolved")
    end
    assert_statement_rejected { KnowledgeImprovementCandidate.where(id: candidate.id).delete_all }
    assert_statement_rejected do
      KnowledgeImprovementCandidate.connection.execute("TRUNCATE knowledge_improvement_candidates")
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

    def create_manual(title, content, expires_at: nil)
      KnowledgeIngestion.create!(
        workspace: @workspace, membership: @owner,
        source_kind: :manual, title:, content:, expires_at:
      )
    end

    def assert_statement_rejected(&block)
      assert_raises(ActiveRecord::StatementInvalid) do
        ActiveRecord::Base.transaction(requires_new: true, &block)
      end
    end
end
