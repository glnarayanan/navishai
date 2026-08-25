class MemoryPublication
  class Conflict < StandardError; end

  def self.propose!(workspace:, artifact:, memory_type:, scope:, topic:, content:, confidence:)
    MemoryProposal.transaction do
      artifact = workspace.crew_artifacts.find(artifact.id)
      artifact.lock!
      agent = workspace.agent_profiles.find(artifact.execution_run.agent_profile_id)
      scope_attributes = proposal_scope!(workspace, scope)
      digest = Digest::SHA256.hexdigest(content.to_s.b)
      proposal = workspace.memory_proposals.find_or_initialize_by(
        source_crew_artifact: artifact, content_digest: digest
      )
      if proposal.persisted?
        expected = scope_attributes.merge(
          source_agent_profile: agent, memory_type: memory_type.to_s, topic: topic.to_s.strip,
          content: content.to_s, confidence: BigDecimal(confidence.to_s)
        )
        current = expected.keys.index_with { |key| proposal.public_send(key) }
        raise Conflict, "proposal input changed for the same source" unless current == expected
        return proposal
      end

      proposal.assign_attributes(
        **scope_attributes, source_agent_profile: agent, memory_type:, topic:, content:, confidence:
      )
      proposal.save!
      AuditEvent.record!(
        action: "memory.proposal_created", source: :runner, workspace:, actor_kind: :system,
        subject: proposal, metadata: { memory_type: proposal.memory_type }
      )
      proposal
    end
  end

  def self.review!(workspace:, proposal:, membership:, outcome:, reviewed_at: Time.current)
    raise ArgumentError, "outcome is invalid" unless outcome.to_s.in?(%w[accepted rejected])

    MemoryProposal.transaction do
      actor = managing_membership!(workspace, membership)
      proposal = workspace.memory_proposals.lock.find(proposal.id)
      return proposal if proposal.status == outcome.to_s
      raise Conflict, "proposal was already reviewed" unless proposal.proposed?

      memory = if outcome.to_s == "accepted"
        publish_accepted!(workspace:, proposal:, actor:, reviewed_at:)
      end
      proposal.update!(
        status: outcome, reviewed_by_membership: actor, reviewed_by_user: actor.user,
        published_memory_record: memory, reviewed_at:
      )
      AuditEvent.record!(
        action: "memory.proposal_reviewed", source: :web, workspace:, actor: actor.user,
        subject: proposal, metadata: { outcome: proposal.status }
      )
      proposal
    end
  end

  def self.publish_procedure!(workspace:, membership:, scope:, topic:, content:, source_reference:,
    idempotency_key:, observed_at: Time.current)
    MemoryRecord.transaction do
      actor = managing_membership!(workspace, membership)
      scope_kind, target = procedure_scope!(workspace, scope)
      record = MemoryCapture.capture!(
        workspace:, capture_key: "procedure:#{idempotency_key}", memory_type: :procedural,
        scope_kind:, scope_target: target, topic:, content:, source_reference:,
        source_digest: Digest::SHA256.hexdigest(content.to_s.b), observed_at:,
        authority: :human_correction, origin_kind: :human,
        source_membership: actor, source_user: actor.user
      )
      unless workspace.audit_events.exists?(
        action: "memory.procedure_published", subject_type: "MemoryRecord", subject_id: record.id
      )
        AuditEvent.record!(
          action: "memory.procedure_published", source: :web, workspace:, actor: actor.user,
          subject: record, metadata: {}
        )
      end
      record
    end
  rescue MemoryCapture::Conflict => error
    raise Conflict, error.message
  end

  def self.publish_accepted!(workspace:, proposal:, actor:, reviewed_at:)
    MemoryCapture.capture!(
      workspace:, capture_key: "proposal:#{proposal.proposal_key}", memory_type: proposal.memory_type,
      scope_kind: proposal.scope_kind, scope_target: proposal.scope_target, topic: proposal.topic,
      content: proposal.content, source_reference: "memory-proposal://#{proposal.proposal_key}",
      source_digest: proposal.content_digest, observed_at: reviewed_at,
      authority: :human_correction, origin_kind: :human,
      source_membership: actor, source_user: actor.user, confidence: proposal.confidence
    )
  end
  private_class_method :publish_accepted!

  def self.proposal_scope!(workspace, scope)
    kind, target = scope_pair(scope)
    raise ArgumentError, "proposal scope is unsupported" unless kind.in?(MemoryProposal::SCOPE_KINDS)
    raise ActiveRecord::RecordNotFound unless target.workspace_id == workspace.id
    { scope_kind: kind, kind.to_sym => target }
  end
  private_class_method :proposal_scope!

  def self.procedure_scope!(workspace, scope)
    kind, target = scope_pair(scope)
    raise ArgumentError, "procedure scope is unsupported" unless kind.in?(MemoryRecord::SCOPE_KINDS)
    valid = target == workspace || (target.respond_to?(:workspace_id) && target.workspace_id == workspace.id)
    valid ||= kind == "user" && workspace.memberships.exists?(user: target)
    unless valid
      raise ActiveRecord::RecordNotFound
    end
    [ kind, target ]
  end
  private_class_method :procedure_scope!

  def self.scope_pair(scope)
    case scope
    when Organization then [ "organization", scope ]
    when Workspace then [ "workspace", scope ]
    when Account then [ "account", scope ]
    when Contact then [ "contact", scope ]
    when SupportCase then [ "support_case", scope ]
    when CrewTemplate then [ "crew", scope ]
    when AgentProfile then [ "agent", scope ]
    when User then [ "user", scope ]
    else raise ArgumentError, "memory scope is unsupported"
    end
  end
  private_class_method :scope_pair

  def self.managing_membership!(workspace, membership)
    workspace.memberships.lock.find(membership.id).tap do |current|
      raise Current::RoleAccessDenied unless current.can_manage_work?
    end
  end
  private_class_method :managing_membership!
end
