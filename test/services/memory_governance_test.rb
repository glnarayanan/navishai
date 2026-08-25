require "test_helper"

class MemoryGovernanceTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
    @member = @workspace.memberships.create!(
      user: User.create!(email_address: "memory-member@example.com", password: "password12345", verified_at: Time.current),
      role: :member
    )
    @memory = create_memory("Original account preference")
  end

  test "a manager publishes an append-only correction with retention and audit history" do
    proposal = nil
    assert_difference [ "MemoryCorrectionProposal.count", "MemoryRecord.count", "MemoryIndexEntry.count" ], 1 do
      proposal = MemoryGovernance.propose_correction!(
        workspace: @workspace, membership: @owner, memory_record: @memory,
        content: "Corrected account preference", confidence: 0.95,
        retention_policy: :time_bound, retention_until: 1.year.from_now
      )
    end

    corrected = proposal.published_memory_record
    assert proposal.accepted?
    assert_equal @memory, corrected.supersedes_memory_record
    assert corrected.authority_human_correction?
    assert corrected.origin_kind_human?
    assert_equal @owner, corrected.source_membership
    assert_equal "Corrected account preference", corrected.content
    assert corrected.retention_policy_time_bound?
    assert_equal %w[memory.correction_proposed memory.correction_reviewed],
      @workspace.audit_events.where(subject_type: "MemoryCorrectionProposal", subject_id: proposal.id).order(:id).pluck(:action)
    assert_raises(MemoryGovernance::Conflict) do
      MemoryGovernance.propose_correction!(
        workspace: @workspace, membership: @owner, memory_record: @memory,
        content: "Stale correction", confidence: 1, retention_policy: :indefinite
      )
    end
  end

  test "a member proposes only against memory used by their run and a manager reviews it" do
    expose_to_member(@memory)
    proposal = MemoryGovernance.propose_correction!(
      workspace: @workspace, membership: @member, memory_record: @memory,
      content: "Member-proposed correction", confidence: 0.8, retention_policy: :indefinite
    )

    assert proposal.proposed?
    assert_nil proposal.published_memory_record
    reviewed = MemoryGovernance.review_correction!(
      workspace: @workspace, membership: @owner, proposal:, outcome: :accepted
    )
    assert reviewed.accepted?
    assert_equal "Member-proposed correction", reviewed.published_memory_record.content

    hidden = create_memory("Never selected")
    assert_raises(ActiveRecord::RecordNotFound) do
      MemoryGovernance.propose_correction!(
        workspace: @workspace, membership: @member, memory_record: hidden,
        content: "Not allowed", confidence: 1, retention_policy: :indefinite
      )
    end
    viewer = @workspace.memberships.create!(user: users(:teammate), role: :viewer)
    assert_raises(Current::RoleAccessDenied) do
      MemoryGovernance.propose_correction!(
        workspace: @workspace, membership: viewer, memory_record: @memory,
        content: "Not allowed", confidence: 1, retention_policy: :indefinite
      )
    end
  end

  test "deletion tombstones immediately and removes the external document with retry visibility" do
    tombstone = MemoryGovernance.delete!(
      workspace: @workspace, membership: @owner, memory_record: @memory, reason: "Customer deletion request"
    )

    assert_equal @memory, tombstone.memory_record
    assert_not_includes @workspace.memory_records.available, @memory
    assert_equal "Customer deletion request", tombstone.reason
    assert_equal @owner, tombstone.deleted_by_membership
    engine = Object.new
    removed = []
    engine.define_singleton_method(:remove) do |**keys|
      removed << keys
      true
    end
    MemoryDeletion.perform!(tombstone:, engine:)
    assert tombstone.reload.index_status_removed?
    assert_equal @memory.memory_key, removed.sole.fetch(:memory_key)

    assert_raises(ActiveRecord::StatementInvalid) do
      MemoryTombstone.transaction(requires_new: true) do
        MemoryTombstone.where(id: tombstone.id).update_all(reason: "Changed")
      end
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      MemoryCorrectionProposal.transaction(requires_new: true) do
        proposal = @workspace.memory_correction_proposals.create!(
          memory_record: create_memory("Proposal target"), proposed_by_membership: @member,
          proposed_by_user: @member.user, content: "Fixed", confidence: 1, retention_policy: :indefinite
        )
        MemoryCorrectionProposal.where(id: proposal.id).update_all(content: "Changed")
      end
    end
  end

  test "deletion waits for active indexing and records an outage for safe retry" do
    entry = @workspace.memory_index_entries.create!(memory_record: @memory)
    entry.update!(status: :indexing, attempt_count: 1, last_attempted_at: Time.current)
    tombstone = MemoryGovernance.delete!(
      workspace: @workspace, membership: @owner, memory_record: @memory, reason: "Remove stale fact"
    )
    never_called = Object.new
    assert_equal tombstone, MemoryDeletion.perform!(tombstone:, engine: never_called)
    assert tombstone.index_status_pending?

    entry.update!(
      status: :failed, external_document_id: nil, external_status: nil,
      failure_code: "unavailable", indexed_at: nil
    )
    unavailable = Object.new
    unavailable.define_singleton_method(:remove) { |**| raise SupermemoryEngine::Unavailable, "offline" }
    MemoryDeletion.perform!(tombstone:, engine: unavailable)
    assert tombstone.reload.index_status_failed?
    assert_equal "unavailable", tombstone.failure_code
    assert_equal 1, tombstone.attempt_count
  end

  private
    def create_memory(content)
      @workspace.memory_records.create!(
        memory_type: :profile, scope_kind: :workspace, topic: "contact-preference", content:,
        authority: :source_record, origin_kind: :system, source_reference: "test://preference",
        source_digest: Digest::SHA256.hexdigest(content), observed_at: 1.day.ago, valid_from: 1.day.ago,
        confidence: 1, retention_policy: :indefinite
      )
    end

    def expose_to_member(memory)
      approve_scripted_runtime(workspace: @workspace, membership: @owner)
      CrewConfiguration.install_defaults!(workspace: @workspace)
      support_case = create_support_case
      profile = @workspace.agent_profiles.find_by!(role_key: "support_investigator")
      task = CrewWork.create!(
        workspace: @workspace, membership: @member, scope: support_case, profile:,
        title: "Member task", input_context: "Use scoped memory.", expected_output: "Return findings."
      )
      @workspace.memory_index_entries.create!(
        memory_record: memory, status: :indexed, attempt_count: 1, external_document_id: "document-1",
        external_status: "done", last_attempted_at: Time.current, indexed_at: Time.current
      )
      engine = Object.new
      engine.define_singleton_method(:search) do |query:|
        [ MemoryEngine::Hit.new(memory_key: memory.memory_key, score: 0.9) ]
      end
      ExecutionLedger.new(workspace: @workspace, memory_engine: engine)
        .prepare!(task:, request_key: "member-memory-run")
    end
end
