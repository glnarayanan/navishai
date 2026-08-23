class CaseWorkflow
  class InvalidTransition < StandardError; end

  TRANSITIONS = {
    "new" => %w[triaged],
    "triaged" => %w[investigating],
    "investigating" => %w[waiting_customer waiting_internal draft_ready resolved],
    "waiting_customer" => %w[investigating],
    "waiting_internal" => %w[investigating],
    "draft_ready" => %w[investigating awaiting_human_review],
    "awaiting_human_review" => %w[investigating resolved],
    "resolved" => %w[closed],
    "closed" => []
  }.freeze
  INBOUND_RESUMABLE = %w[waiting_customer resolved closed].freeze

  def self.transition!(workspace:, support_case:, membership:, to:, reason:, occurred_at: Time.current)
    SupportCase.transaction do
      actor = authorized_membership!(workspace, membership)
      current_case = workspace.support_cases.lock.find(support_case.id)
      change_status!(current_case, to.to_s, reason:, occurred_at:, source: :web, actor: actor.user)
    end
  end

  def self.assign!(workspace:, support_case:, membership:, assignee:)
    SupportCase.transaction do
      actor = managing_membership!(workspace, membership)
      current_case = workspace.support_cases.lock.find(support_case.id)
      target = assignee && workspace.memberships.find(assignee.id)
      raise Current::RoleAccessDenied if target&.viewer?
      return current_case if current_case.assigned_membership == target

      current_case.update!(assigned_membership: target)
      AuditEvent.record!(
        action: target ? "case.assigned" : "case.unassigned",
        source: :web,
        workspace: workspace,
        actor: actor.user,
        subject: current_case,
        metadata: target ? { assignee_id: target.id } : {}
      )
      current_case
    end
  end

  def self.prioritize!(workspace:, support_case:, membership:, priority:)
    SupportCase.transaction do
      actor = authorized_membership!(workspace, membership)
      current_case = workspace.support_cases.lock.find(support_case.id)
      previous = current_case.priority
      return current_case if previous == priority.to_s

      current_case.update!(priority: priority)
      AuditEvent.record!(
        action: "case.priority_changed",
        source: :web,
        workspace: workspace,
        actor: actor.user,
        subject: current_case,
        metadata: { from_priority: previous, to_priority: current_case.priority }
      )
      current_case
    end
  end

  def self.create_tag!(workspace:, membership:, name:)
    Tag.transaction do
      actor = managing_membership!(workspace, membership)
      tag = workspace.tags.create!(name: name)
      AuditEvent.record!(action: "tag.created", source: :web, workspace: workspace, actor: actor.user, subject: tag)
      tag
    end
  end

  def self.tag!(workspace:, support_case:, membership:, tag:)
    change_tag!(workspace:, support_case:, membership:, tag:, adding: true)
  end

  def self.untag!(workspace:, support_case:, membership:, tag:)
    change_tag!(workspace:, support_case:, membership:, tag:, adding: false)
  end

  def self.add_note!(workspace:, support_case:, membership:, body:)
    CaseNote.transaction do
      actor = authorized_membership!(workspace, membership)
      current_case = workspace.support_cases.lock.find(support_case.id)
      note = workspace.case_notes.create!(support_case: current_case, author: actor.user, body: body)
      AuditEvent.record!(action: "case.note_added", source: :web, workspace: workspace, actor: actor.user, subject: note)
      note
    end
  end

  def self.resume_for_inbound!(workspace:, support_case:, source:, occurred_at:)
    current_case = workspace.support_cases.lock.find(support_case.id)
    return current_case unless INBOUND_RESUMABLE.include?(current_case.status)

    change_status!(current_case, "investigating", reason: "new inbound message", occurred_at: occurred_at, source: source, actor: nil, inbound: true)
  end

  def self.change_tag!(workspace:, support_case:, membership:, tag:, adding:)
    SupportCaseTagging.transaction do
      actor = authorized_membership!(workspace, membership)
      current_case = workspace.support_cases.lock.find(support_case.id)
      current_tag = workspace.tags.find(tag.id)
      tagging = workspace.support_case_taggings.find_by(support_case: current_case, tag: current_tag)
      return adding ? tagging : current_case unless adding != tagging.present?

      if adding
        tagging = workspace.support_case_taggings.create!(support_case: current_case, tag: current_tag)
      else
        tagging.destroy!
      end
      AuditEvent.record!(
        action: adding ? "case.tag_added" : "case.tag_removed",
        source: :web,
        workspace: workspace,
        actor: actor.user,
        subject: current_case,
        metadata: { tag_id: current_tag.id }
      )
      adding ? tagging : current_case
    end
  end
  private_class_method :change_tag!

  def self.change_status!(support_case, target, reason:, occurred_at:, source:, actor:, inbound: false)
    from = support_case.status
    allowed = inbound ? target == "investigating" && INBOUND_RESUMABLE.include?(from) : TRANSITIONS.fetch(from).include?(target)
    raise InvalidTransition, "cannot transition from #{from} to #{target}" unless allowed
    raise ArgumentError, "reason is required" if reason.to_s.strip.empty?

    resolved_at = target == "resolved" ? occurred_at : nil
    closed_at = target == "closed" ? occurred_at : nil
    resolved_at = support_case.resolved_at if target == "closed"
    support_case.update!(status: target, status_changed_at: occurred_at, resolved_at: resolved_at, closed_at: closed_at)
    change = support_case.status_changes.create!(
      workspace: support_case.workspace,
      from_status: from,
      to_status: target,
      actor_kind: actor ? :user : :system,
      actor: actor,
      source: source,
      reason: reason,
      occurred_at: occurred_at
    )
    AuditEvent.record!(
      action: "case.status_changed",
      source: source,
      workspace: support_case.workspace,
      actor: actor,
      actor_kind: actor ? nil : :system,
      subject: change,
      metadata: { from_status: from, to_status: target }
    )
    support_case
  end
  private_class_method :change_status!

  def self.authorized_membership!(workspace, membership)
    workspace.memberships.lock.find(membership.id).tap do |current_membership|
      raise Current::RoleAccessDenied unless current_membership.can_write?
    end
  end
  private_class_method :authorized_membership!

  def self.managing_membership!(workspace, membership)
    authorized_membership!(workspace, membership).tap do |current_membership|
      raise Current::RoleAccessDenied unless current_membership.can_manage_work?
    end
  end
  private_class_method :managing_membership!
end
