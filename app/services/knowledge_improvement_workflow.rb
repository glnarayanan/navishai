class KnowledgeImprovementWorkflow
  class InvalidCommand < StandardError; end

  def self.create_from_blocked_draft!(workspace:, membership:, artifact:, at: Time.current)
    new(workspace:, membership:).create_from_blocked_draft!(artifact:, at:)
  end

  def self.create_from_source!(workspace:, membership:, knowledge_source:, at: Time.current)
    new(workspace:, membership:).create_from_source!(knowledge_source:, at:)
  end

  def self.triage!(workspace:, membership:, candidate:, note:, at: Time.current)
    new(workspace:, membership:).triage!(candidate:, note:, at:)
  end

  def self.assign!(workspace:, membership:, candidate:, assignee:, at: Time.current)
    new(workspace:, membership:).assign!(candidate:, assignee:, at:)
  end

  def self.resolve!(workspace:, membership:, candidate:, knowledge_source:, at: Time.current)
    new(workspace:, membership:).resolve!(candidate:, knowledge_source:, at:)
  end

  def self.dismiss!(workspace:, membership:, candidate:, reason:, at: Time.current)
    new(workspace:, membership:).dismiss!(candidate:, reason:, at:)
  end

  def initialize(workspace:, membership:)
    @workspace = workspace
    @membership = workspace.memberships.find(membership.id)
  end

  def create_from_blocked_draft!(artifact:, at:)
    authorize_write!
    artifact = @workspace.crew_artifacts.includes(crew_task: :support_case).find(artifact.id)
    support_case = artifact.crew_task.support_case
    raise InvalidCommand, "Choose a current blocked resolution draft." unless
      artifact.artifact_kind == "draft" && artifact.contract_blocking? && artifact.revisions.none? && support_case

    create_candidate!(
      source_crew_artifact: artifact, support_case:, knowledge_source: nil,
      reason_code: "missing_knowledge",
      title: support_case.conversation.subject,
      detail: blocked_detail(artifact),
      at:
    )
  end

  def create_from_source!(knowledge_source:, at:)
    authorize_write!
    source = @workspace.knowledge_sources.includes(:current_version, :knowledge_sync_observation).find(knowledge_source.id)
    reason = source_reason(source)
    raise InvalidCommand, "That source does not currently need improvement." unless reason

    create_candidate!(
      source_crew_artifact: nil, support_case: nil, knowledge_source: source,
      reason_code: reason,
      title: source.display_title,
      detail: source_detail(source, reason),
      at:
    )
  end

  def triage!(candidate:, note:, at:)
    authorize_manager!
    note = bounded_text(note, 1_000, "Triage note")
    change(candidate) do |record|
      raise InvalidCommand, "Only an open candidate can be triaged." unless record.open?
      record.status = :triaged
      record.triaged_by_membership = @membership
      record.triaged_at = at
      record.triage_note = note
      audit!("knowledge.improvement_triaged", record, { "from_state" => "open", "to_state" => "triaged" }, at)
    end
  end

  def assign!(candidate:, assignee:, at:)
    authorize_manager!
    assignee = @workspace.memberships.find(assignee.id)
    raise InvalidCommand, "Choose a human who can maintain knowledge." unless assignee.can_manage_work?

    change(candidate) do |record|
      unless record.open? || record.triaged? || record.assigned?
        raise InvalidCommand, "Only an open, triaged, or assigned candidate can be assigned."
      end
      raise InvalidCommand, "Choose a different eligible human." if record.assigned_to_membership_id == assignee.id

      from = record.status
      previous_id = record.assigned_to_membership_id
      record.status = :assigned
      record.assigned_to_membership = assignee
      record.assigned_by_membership = @membership
      record.assigned_at = at
      metadata = {
        "from_state" => from, "to_state" => "assigned", "assignee_membership_id" => assignee.id
      }
      metadata["previous_assignee_membership_id"] = previous_id if previous_id
      audit!("knowledge.improvement_assigned", record, metadata, at)
    end
  end

  def resolve!(candidate:, knowledge_source:, at:)
    authorize_manager!
    source = @workspace.knowledge_sources.includes(:current_version).find(knowledge_source.id)
    version = source.current_version
    raise InvalidCommand, "Link a current authorised knowledge version." if version.blank? || source.deleted? || source.stale?

    change(candidate) do |record|
      raise InvalidCommand, "Assign the candidate before linking a knowledge version." unless record.assigned?
      record.status = :resolved
      record.resolved_knowledge_source = source
      record.resolved_knowledge_source_version = version
      record.resolved_by_membership = @membership
      record.resolved_at = at
      audit!("knowledge.improvement_resolved", record, {
        "from_state" => "assigned", "to_state" => "resolved",
        "knowledge_source_version_id" => version.id
      }, at)
    end
  end

  def dismiss!(candidate:, reason:, at:)
    authorize_manager!
    reason = bounded_text(reason, 1_000, "Dismissal reason")
    change(candidate) do |record|
      unless record.open? || record.triaged? || record.assigned?
        raise InvalidCommand, "A resolved or dismissed candidate cannot be dismissed."
      end
      from = record.status
      record.status = :dismissed
      record.dismissed_by_membership = @membership
      record.dismissed_at = at
      record.dismissal_reason = reason
      audit!("knowledge.improvement_dismissed", record, { "from_state" => from, "to_state" => "dismissed" }, at)
    end
  end

  private
    def create_candidate!(source_crew_artifact:, support_case:, knowledge_source:, reason_code:, title:, detail:, at:)
      KnowledgeImprovementCandidate.transaction do
        candidate = @workspace.knowledge_improvement_candidates.create!(
          source_crew_artifact:, support_case:, knowledge_source:, reason_code:,
          title: bounded_text(title, 200, "Title"), detail: bounded_text(detail, 2_000, "Detail"),
          status: :open, created_by_membership: @membership, opened_at: at
        )
        audit!("knowledge.improvement_created", candidate, {
          "from_state" => "none", "to_state" => "open", "reason_code" => reason_code
        }, at)
        candidate
      end
    rescue ActiveRecord::RecordInvalid => error
      raise InvalidCommand, error.record.errors.full_messages.to_sentence
    rescue ActiveRecord::RecordNotUnique
      raise InvalidCommand, "That improvement candidate already exists."
    end

    def change(candidate)
      record = @workspace.knowledge_improvement_candidates.find(candidate.id)
      record.with_lock do
        yield record
        record.save!
        record
      end
    rescue ActiveRecord::RecordInvalid => error
      raise InvalidCommand, error.record.errors.full_messages.to_sentence
    end

    def authorize_write!
      raise Current::RoleAccessDenied unless @membership.can_write?
    end

    def authorize_manager!
      raise Current::RoleAccessDenied unless @membership.can_manage_work?
    end

    def bounded_text(value, maximum, label)
      text = value.to_s.strip
      raise InvalidCommand, "#{label} must be between 1 and #{maximum} bytes." unless text.bytesize.in?(1..maximum)
      text
    end

    def blocked_detail(artifact)
      blocker = Array(artifact.contract_blockers).first
      message = blocker.is_a?(Hash) ? blocker["message"].presence : nil
      message.presence || "The current resolution draft is blocked because applicable knowledge is missing."
    end

    def source_reason(source)
      observation = source.knowledge_sync_observation
      if observation&.retired_at.present?
        "retired"
      elsif source.deleted_at.present?
        "deleted"
      elsif source.stale?
        "stale"
      elsif failed_sync?(source)
        "failed_sync"
      end
    end

    def source_detail(source, reason)
      case reason
      when "retired"
        "Two complete absences removed this source from current search."
      when "deleted"
        "A knowledge manager removed this source from current use."
      when "stale"
        source.knowledge_sync_observation&.unavailable_at.present? ?
          "The last complete sync did not confirm this source." :
          "The current version has expired."
      else
        "The latest sync pass for this source failed."
      end
    end

    def failed_sync?(source)
      passes = @workspace.knowledge_sync_passes.where(status: "failed", completed_at: nil)
      if source.intercom_connection_id
        passes.exists?(intercom_connection_id: source.intercom_connection_id)
      elsif source.notion_knowledge_connection_id
        passes.exists?(notion_knowledge_connection_id: source.notion_knowledge_connection_id)
      else
        false
      end
    end

    def audit!(action, candidate, metadata, at)
      AuditEvent.record!(
        action:, source: :web, workspace: @workspace, actor: @membership.user,
        subject: candidate, metadata:, occurred_at: at
      )
    end
end
