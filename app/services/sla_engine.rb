class SlaEngine
  PAUSED_STATUSES = %w[waiting_customer].freeze
  OBJECTIVES = %w[first_response resolution].freeze

  def self.start!(workspace:, support_case:, at: Time.current)
    CaseSla.transaction do
      current_case = workspace.support_cases.lock.find(support_case.id)
      return current_case.case_sla if current_case.case_sla

      policy = workspace.sla_policies.active.find_by(priority: current_case.priority)
      return unless policy

      calendar = policy.service_calendar
      case_sla = workspace.case_slas.create!(
        support_case: current_case,
        sla_policy: policy,
        started_at: at,
        first_response_warning_at: warning_at(calendar, at, policy.first_response_minutes, policy.warning_percent),
        first_response_due_at: calendar.add_business_minutes(at, policy.first_response_minutes),
        resolution_warning_at: warning_at(calendar, at, policy.resolution_minutes, policy.warning_percent),
        resolution_due_at: calendar.add_business_minutes(at, policy.resolution_minutes)
      )
      AuditEvent.record!(
        action: "case.sla_started", source: :system, workspace: workspace,
        actor_kind: :system, subject: case_sla, metadata: { policy_id: policy.id }
      )
      case_sla
    end
  end

  def self.status_changed!(workspace:, support_case:, from:, to:, at: Time.current)
    CaseSla.transaction do
      case_sla = workspace.case_slas.lock.find_by(support_case_id: support_case.id)
      return unless case_sla

      pause!(case_sla, at) if PAUSED_STATUSES.include?(to) && !PAUSED_STATUSES.include?(from)
      resume!(case_sla, at) if PAUSED_STATUSES.include?(from) && !PAUSED_STATUSES.include?(to)
      reopen_resolution!(case_sla, at) if %w[resolved closed].include?(from) && to == "investigating"
      complete_objective!(case_sla, "resolution", at) if to == "resolved"
      case_sla
    end
  end

  def self.record_first_response!(workspace:, support_case:, message:)
    CaseSla.transaction do
      current_case = workspace.support_cases.lock.find(support_case.id)
      current_message = workspace.conversation_messages.find(message.id)
      unless current_message.outbound? && current_message.conversation_id == current_case.conversation_id
        raise ArgumentError, "first response requires an outbound message from the case conversation"
      end

      case_sla = workspace.case_slas.lock.find_by!(support_case: current_case)
      return case_sla if case_sla.first_responded_at && case_sla.first_responded_at <= current_message.occurred_at

      complete_objective!(case_sla, "first_response", current_message.occurred_at, replace_if_earlier: true)
    end
  end

  def self.evaluate!(workspace:, at: Time.current)
    workspace.case_slas.where(paused_at: nil).find_each do |case_sla|
      CaseSla.transaction do
        current_sla = workspace.case_slas.lock.find(case_sla.id)
        next if current_sla.paused_at

        OBJECTIVES.each { |objective| evaluate_objective!(current_sla, objective, at) }
      end
    end
  end

  def self.warning_at(calendar, at, target_minutes, warning_percent)
    warning_minutes = [ (target_minutes * warning_percent / 100.0).ceil, target_minutes - 1 ].min
    calendar.add_business_minutes(at, warning_minutes)
  end
  private_class_method :warning_at

  def self.pause!(case_sla, at)
    case_sla.update!(paused_at: at) unless case_sla.paused_at
  end
  private_class_method :pause!

  def self.resume!(case_sla, at)
    return unless case_sla.paused_at

    calendar = case_sla.sla_policy.service_calendar
    paused_seconds = calendar.business_seconds_between(case_sla.paused_at, at)
    updates = { paused_at: nil, paused_business_seconds: case_sla.paused_business_seconds + paused_seconds }
    OBJECTIVES.each do |objective|
      next unless case_sla.public_send("#{objective}_pending?")

      updates["#{objective}_warning_at"] = calendar.add_business_seconds(case_sla.public_send("#{objective}_warning_at"), paused_seconds)
      updates["#{objective}_due_at"] = calendar.add_business_seconds(case_sla.public_send("#{objective}_due_at"), paused_seconds)
    end
    case_sla.update!(updates)
  end
  private_class_method :resume!

  def self.reopen_resolution!(case_sla, at)
    return unless case_sla.resolved_at

    calendar = case_sla.sla_policy.service_calendar
    terminal_seconds = calendar.business_seconds_between(case_sla.resolved_at, at)
    case_sla.update!(
      resolution_status: "pending",
      resolved_at: nil,
      resolution_warning_at: calendar.add_business_seconds(case_sla.resolution_warning_at, terminal_seconds),
      resolution_due_at: calendar.add_business_seconds(case_sla.resolution_due_at, terminal_seconds)
    )
  end
  private_class_method :reopen_resolution!

  def self.evaluate_objective!(case_sla, objective, at)
    return unless case_sla.public_send("#{objective}_pending?")

    warning_at = case_sla.public_send("#{objective}_warning_at")
    due_at = case_sla.public_send("#{objective}_due_at")
    create_escalation!(case_sla, objective, "warning", at) if at >= warning_at
    return unless at >= due_at

    case_sla.update!("#{objective}_status" => "breached")
    case_sla.escalation_tasks.where(objective: objective, kind: :warning, status: :open).update_all(status: "completed", updated_at: at)
    create_escalation!(case_sla, objective, "breach", at)
  end
  private_class_method :evaluate_objective!

  def self.complete_objective!(case_sla, objective, at, replace_if_earlier: false)
    completed_at_field = objective == "first_response" ? :first_responded_at : :resolved_at
    completed_at = case_sla.public_send(completed_at_field)
    return case_sla if completed_at && (!replace_if_earlier || completed_at <= at)

    due_at = case_sla.public_send("#{objective}_due_at")
    status = at <= due_at ? "met" : "breached"
    case_sla.update!(completed_at_field => at, "#{objective}_status" => status)
    tasks = case_sla.escalation_tasks.where(objective: objective, status: :open)
    tasks = tasks.where(kind: :warning) if status == "breached"
    tasks.update_all(status: "completed", updated_at: at)
    create_escalation!(case_sla, objective, "breach", at) if status == "breached"
    case_sla
  end
  private_class_method :complete_objective!

  def self.create_escalation!(case_sla, objective, kind, at)
    task = case_sla.escalation_tasks.find_or_create_by!(objective: objective, kind: kind) do |record|
      record.workspace = case_sla.workspace
      record.occurred_at = at
    end
    if !task.previously_new_record? && task.completed?
      task.update!(status: :open)
      AuditEvent.record!(
        action: "sla.escalation_reactivated", source: :system, workspace: case_sla.workspace,
        actor_kind: :system, subject: task, metadata: { objective: objective, kind: kind }
      )
      return task
    end
    return task unless task.previously_new_record?

    AuditEvent.record!(
      action: "sla.escalation_created", source: :system, workspace: case_sla.workspace,
      actor_kind: :system, subject: task, metadata: { objective: objective, kind: kind }
    )
    task
  end
  private_class_method :create_escalation!
end
