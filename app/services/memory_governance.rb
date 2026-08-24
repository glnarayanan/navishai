class MemoryGovernance
  class Conflict < StandardError; end

  def self.propose_correction!(workspace:, membership:, memory_record:, content:, confidence:,
    retention_policy:, retention_until: nil, proposed_at: Time.current)
    MemoryCorrectionProposal.transaction do
      actor = inspecting_membership!(workspace, membership)
      memory_id = accessible_records(workspace, actor).find(memory_record.id).id
      memory = workspace.memory_records.lock.find(memory_id)
      ensure_correctable!(memory)
      proposal = workspace.memory_correction_proposals.create!(
        memory_record: memory, proposed_by_membership: actor, proposed_by_user: actor.user,
        content:, confidence:, retention_policy:, retention_until:
      )
      AuditEvent.record!(
        action: "memory.correction_proposed", source: :web, workspace:, actor: actor.user,
        subject: proposal, metadata: {}, occurred_at: proposed_at
      )
      review_locked!(workspace:, proposal:, actor:, outcome: :accepted, reviewed_at: proposed_at) if actor.can_manage_work?
      proposal
    end
  end

  def self.review_correction!(workspace:, membership:, proposal:, outcome:, reviewed_at: Time.current)
    raise ArgumentError, "outcome is invalid" unless outcome.to_s.in?(%w[accepted rejected])

    MemoryCorrectionProposal.transaction do
      actor = managing_membership!(workspace, membership)
      proposal = workspace.memory_correction_proposals.lock.find(proposal.id)
      return proposal if proposal.status == outcome.to_s
      raise Conflict, "correction was already reviewed" unless proposal.proposed?

      review_locked!(workspace:, proposal:, actor:, outcome:, reviewed_at:)
    end
  end

  def self.delete!(workspace:, membership:, memory_record:, reason:)
    MemoryTombstone.transaction do
      actor = managing_membership!(workspace, membership)
      memory = workspace.memory_records.lock.find(memory_record.id)
      tombstone = workspace.memory_tombstones.find_by(memory_record: memory)
      return tombstone if tombstone

      tombstone = workspace.memory_tombstones.create!(
        memory_record: memory, deleted_by_membership: actor, deleted_by_user: actor.user, reason:
      )
      AuditEvent.record!(
        action: "memory.record_deleted", source: :web, workspace:, actor: actor.user,
        subject: memory, metadata: {}
      )
      MemoryDeletionJob.enqueue_after_commit(tombstone)
      tombstone
    end
  end

  def self.retry_deletion!(workspace:, membership:, tombstone:)
    MemoryTombstone.transaction do
      actor = managing_membership!(workspace, membership)
      tombstone = workspace.memory_tombstones.lock.find(tombstone.id)
      raise Conflict, "index removal does not need retry" unless tombstone.index_status_failed? || tombstone.index_status_unknown?

      AuditEvent.record!(
        action: "memory.index_removal_retried", source: :web, workspace:, actor: actor.user,
        subject: tombstone.memory_record, metadata: {}
      )
      MemoryDeletionJob.enqueue_after_commit(tombstone)
      tombstone
    end
  end

  def self.accessible_records(workspace, membership)
    return workspace.memory_records if membership.can_manage_work?

    workspace.memory_records.joins(execution_memory_selections: { execution_run: :crew_task })
      .where(crew_tasks: { owner_membership_id: membership.id }).distinct
  end

  def self.review_locked!(workspace:, proposal:, actor:, outcome:, reviewed_at:)
    memory = nil
    if outcome.to_s == "accepted"
      source = workspace.memory_records.lock.find(proposal.memory_record_id)
      ensure_correctable!(source)
      memory = publish_correction!(workspace:, source:, proposal:, actor:, reviewed_at:)
    end
    proposal.update!(
      status: outcome, reviewed_by_membership: actor, reviewed_by_user: actor.user,
      published_memory_record: memory, reviewed_at:
    )
    AuditEvent.record!(
      action: "memory.correction_reviewed", source: :web, workspace:, actor: actor.user,
      subject: proposal, metadata: { outcome: proposal.status }, occurred_at: reviewed_at
    )
    proposal
  end
  private_class_method :review_locked!

  def self.publish_correction!(workspace:, source:, proposal:, actor:, reviewed_at:)
    scope = MemoryCapture.scope_attributes(source.scope_kind, source.scope_target)
    memory = workspace.memory_records.create!(
      **scope, memory_type: source.memory_type, topic: source.topic, content: proposal.content,
      authority: :human_correction, origin_kind: :human,
      source_reference: "memory-correction://#{proposal.proposal_key}", source_digest: proposal.content_digest,
      observed_at: reviewed_at, valid_from: reviewed_at, confidence: proposal.confidence,
      retention_policy: proposal.retention_policy, retention_until: proposal.retention_until,
      source_membership: actor, source_user: actor.user, supersedes_memory_record: source
    )
    entry = workspace.memory_index_entries.create!(memory_record: memory)
    MemoryIndexJob.enqueue_after_commit(entry)
    memory
  end
  private_class_method :publish_correction!

  def self.ensure_correctable!(memory)
    raise Conflict, "deleted memory cannot be corrected" if memory.memory_tombstone
    raise Conflict, "a newer memory record already exists" if memory.revisions.exists?
  end
  private_class_method :ensure_correctable!

  def self.inspecting_membership!(workspace, membership)
    workspace.memberships.lock.find(membership.id).tap do |current|
      raise Current::RoleAccessDenied unless current.can_inspect_memory?
    end
  end
  private_class_method :inspecting_membership!

  def self.managing_membership!(workspace, membership)
    inspecting_membership!(workspace, membership).tap do |current|
      raise Current::RoleAccessDenied unless current.can_manage_work?
    end
  end
  private_class_method :managing_membership!
end
