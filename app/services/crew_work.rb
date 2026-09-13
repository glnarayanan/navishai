class CrewWork
  class InvalidCommand < StandardError; end
  class StaleTask < InvalidCommand; end

  COMMANDS = %w[start block resume comment add_evidence handoff request_review review fail cancel retry].freeze
  TRANSITIONS = {
    "pending" => %w[ready blocked canceled],
    "ready" => %w[in_progress blocked canceled],
    "in_progress" => %w[blocked review_requested completed failed canceled],
    "blocked" => %w[ready in_progress failed canceled],
    "review_requested" => %w[in_progress completed failed],
    "failed" => %w[ready canceled],
    "completed" => [],
    "canceled" => []
  }.freeze

  def self.create!(workspace:, membership:, scope:, profile:, title:, input_context:, expected_output:, dependencies: [])
    new(workspace:, membership:).create!(scope:, profile:, title:, input_context:, expected_output:, dependencies:)
  end

  def self.apply!(workspace:, membership:, task:, command:, expected_sequence:, attributes: {})
    new(workspace:, membership:).apply!(task:, command:, expected_sequence:, attributes:)
  end

  def initialize(workspace:, membership: nil)
    @workspace = workspace
    @membership = membership && workspace.memberships.find(membership.id)
  end

  def create!(scope:, profile:, title:, input_context:, expected_output:, dependencies: [])
    authorize_write!
    scope = scoped_record!(scope)
    profile = @workspace.agent_profiles.includes(:current_version).find(profile.id)
    expected_crew = scope.is_a?(SupportCase) ? "support" : "customer_success"
    raise InvalidCommand, "Choose a specialist from the #{expected_crew.tr('_', ' ')} crew." unless profile.crew_template.crew_kind == expected_crew
    if scope.is_a?(HealthScorecard) && profile.role_key != "success_strategist"
      raise InvalidCommand, "Scorecard proposals use the Success Strategist."
    end

    dependency_ids = Array(dependencies).map { |dependency| dependency.respond_to?(:id) ? dependency.id : dependency }.compact_blank.map(&:to_i).uniq
    dependencies = @workspace.crew_tasks.where(id: dependency_ids).order(:id).to_a
    raise InvalidCommand, "One or more dependencies are unavailable." unless dependencies.size == dependency_ids.size
    unless dependencies.all? { |dependency| same_scope?(dependency, scope) }
      raise InvalidCommand, "Dependencies must belong to the same case, account, or scorecard."
    end

    CrewTask.transaction do
      GovernedPolicyResolver.lock_workspace!(@workspace)
      lock_scope!(scope)
      policy = GovernedPolicyResolver.resolve(workspace: @workspace, scope:, profile:)
      status = dependencies.all?(&:completed?) ? "ready" : "pending"
      task = @workspace.crew_tasks.create!(
        scope_kind: scope_kind(scope), scope_association(scope) => scope,
        crew_template: profile.crew_template,
        assigned_agent_profile: profile,
        assigned_agent_profile_version: policy.agent_profile_version,
        governed_policy_publication: policy.publication,
        resolution_contract_version: policy.resolution_contract_version,
        owner_membership: @membership, owner_user: @membership.user,
        title: title.to_s.strip, input_context: input_context.to_s.strip,
        expected_output: expected_output.to_s.strip, status:
      )
      dependencies.each do |dependency|
        task.dependency_links.create!(workspace: @workspace, depends_on_task: dependency)
      end
      append_event!(task, kind: "created", to_status: status, to_profile: profile)
      AuditEvent.record!(action: "crew.task_created", source: :web, workspace: @workspace,
        actor: @membership.user, subject: task)
      task
    end
  rescue ActiveRecord::RecordInvalid => error
    raise InvalidCommand, error.record.errors.full_messages.to_sentence
  end

  def apply!(task:, command:, expected_sequence:, attributes: {})
    authorize_write!
    command = command.to_s
    raise InvalidCommand, "Unknown task command." unless COMMANDS.include?(command)

    task = @workspace.crew_tasks.find(task.id)
    CrewTask.transaction do
      lock_scope!(task.scope_record)
      task.lock!
      expected = Integer(expected_sequence.to_s, 10)
      raise StaleTask, "This task changed after the page loaded. Review the latest work record and try again." unless task.current_event.sequence_number == expected

      values = attributes.respond_to?(:to_h) ? attributes.to_h : attributes
      if command.in?(%w[block handoff request_review fail cancel]) && task.execution_runs.active.exists?
        raise InvalidCommand, "Wait for the active run to finish or confirm cancellation before changing this task."
      end
      event = apply_command!(task, command, values.symbolize_keys)
      AuditEvent.record!(
        action: "crew.task_event_recorded", source: :web, workspace: @workspace,
        actor: @membership.user, subject: event, metadata: { "event_kind" => event.event_kind }
      )
      refresh_dependents!(task) if task.completed?
      task
    end
  rescue ArgumentError, TypeError
    raise InvalidCommand, "The task version is invalid."
  rescue ActiveRecord::RecordInvalid => error
    raise InvalidCommand, error.record.errors.full_messages.to_sentence
  end

  private
    def apply_command!(task, command, attributes)
      case command
      when "start"
        transition!(task, "in_progress", "status_changed", attributes[:body])
      when "block"
        transition!(task, "blocked", "status_changed", required_body(attributes[:body], "Say what is blocking this task."))
      when "resume"
        raise InvalidCommand, "This task still has incomplete dependencies." unless task.dependencies.all?(&:completed?)
        transition!(task, "ready", "status_changed", attributes[:body])
      when "comment"
        append_same_state!(task, "comment", required_body(attributes[:body], "Write a comment."))
      when "add_evidence"
        evidence_kind = attributes[:evidence_kind].to_s
        raise InvalidCommand, "Choose an evidence type." unless CrewTaskEvent::EVIDENCE_KINDS.include?(evidence_kind)
        locator = required_body(attributes[:evidence_locator], "Add a stable evidence reference.")
        raise InvalidCommand, "Evidence references must be 2,000 bytes or less." if locator.bytesize > 2_000

        append_same_state!(task, "evidence_added", required_body(attributes[:body], "Explain what this evidence supports."),
          evidence_kind:, evidence_locator: locator)
      when "handoff"
        raise InvalidCommand, "A finished task cannot be handed off." if task.completed? || task.canceled?
        profile = @workspace.agent_profiles.includes(:current_version).find(attributes[:agent_profile_id])
        raise InvalidCommand, "The specialist must belong to this crew." unless profile.crew_template_id == task.crew_template_id
        raise InvalidCommand, "Choose a different specialist." if profile == task.assigned_agent_profile

        append_event!(task, kind: "handoff", to_status: task.status, to_profile: profile,
          body: required_body(attributes[:body], "Explain the handoff."))
      when "request_review"
        transition!(task, "review_requested", "review_requested", required_body(attributes[:body], "State what needs review."))
      when "review"
        authorize_review!
        raise InvalidCommand, "This task is not waiting for review." unless task.review_requested?
        outcome = attributes[:review_outcome].to_s
        raise InvalidCommand, "Choose a review outcome." unless CrewTaskEvent::REVIEW_OUTCOMES.include?(outcome)
        latest_artifact = task.artifacts.unscope(:order).order(created_at: :desc, id: :desc).first
        if outcome == "approved" && latest_artifact&.contract_blocking?
          raise InvalidCommand, "A blocking AI result cannot receive an approved outcome review."
        end
        target = outcome == "approved" ? "completed" : "in_progress"
        kind = outcome == "approved" ? "outcome_recorded" : "review_resolved"
        append_event!(task, kind:, to_status: target, to_profile: task.assigned_agent_profile,
          body: required_body(attributes[:body], "Record the review decision."), review_outcome: outcome,
          outcome_kind: outcome == "approved" ? "completed" : nil)
      when "fail"
        append_event!(task, kind: "outcome_recorded", to_status: "failed", to_profile: task.assigned_agent_profile,
          body: required_body(attributes[:body], "Record why this task failed."), outcome_kind: "failed")
      when "cancel"
        append_event!(task, kind: "outcome_recorded", to_status: "canceled", to_profile: task.assigned_agent_profile,
          body: required_body(attributes[:body], "Record why this task was canceled."), outcome_kind: "canceled")
      when "retry"
        raise InvalidCommand, "This task still has incomplete dependencies." unless task.dependencies.all?(&:completed?)
        transition!(task, "ready", "status_changed", required_body(attributes[:body], "Record why this task should be retried."))
      end
    end

    def transition!(task, target, kind, body)
      append_event!(task, kind:, to_status: target, to_profile: task.assigned_agent_profile, body: body.to_s.strip.presence)
    end

    def append_same_state!(task, kind, body, **attributes)
      append_event!(task, kind:, to_status: task.status, to_profile: task.assigned_agent_profile, body:, **attributes)
    end

    def append_event!(task, kind:, to_status:, to_profile:, body: nil, **attributes)
      old_event = task.current_event
      if old_event && task.status != to_status && TRANSITIONS.fetch(task.status).exclude?(to_status)
        raise InvalidCommand, "That command is not available while the task is #{task.status.humanize.downcase}."
      end
      policy = if to_profile == task.assigned_agent_profile
        nil
      else
        GovernedPolicyResolver.lock_workspace!(@workspace)
        GovernedPolicyResolver.resolve(workspace: @workspace, scope: task.scope_record, profile: to_profile)
      end
      to_version = policy&.agent_profile_version || task.assigned_agent_profile_version
      to_publication = policy ? policy.publication : task.governed_policy_publication
      to_contract = policy ? policy.resolution_contract_version : task.resolution_contract_version
      event = task.events.create!(
        workspace: @workspace, sequence_number: old_event&.sequence_number.to_i + 1,
        event_kind: kind, source: "web",
        actor_membership: @membership, actor_user: @membership&.user,
        from_status: old_event ? task.status : nil, to_status:,
        from_agent_profile: old_event ? task.assigned_agent_profile : nil,
        to_agent_profile: to_profile,
        from_agent_profile_version: old_event ? task.assigned_agent_profile_version : nil,
        to_agent_profile_version: to_version,
        from_governed_policy_publication: old_event ? task.governed_policy_publication : nil,
        to_governed_policy_publication: to_publication,
        from_resolution_contract_version: old_event ? task.resolution_contract_version : nil,
        to_resolution_contract_version: to_contract,
        body:, **attributes
      )
      task.update!(
        status: to_status,
        assigned_agent_profile: to_profile,
        assigned_agent_profile_version: to_version,
        governed_policy_publication: to_publication,
        resolution_contract_version: to_contract,
        current_event: event
      )
      event
    end

    def refresh_dependents!(task)
      @workspace.crew_tasks.joins(:dependency_links)
        .where(crew_task_dependencies: { depends_on_task_id: task.id }, status: :pending).order(:id).each do |dependent|
        dependent.lock!
        next unless dependent.dependencies.all?(&:completed?)

        event = append_event!(dependent, kind: "status_changed", to_status: "ready",
          to_profile: dependent.assigned_agent_profile, body: "All dependencies completed.")
        AuditEvent.record!(action: "crew.task_event_recorded", source: :web, workspace: @workspace,
          actor: @membership.user, subject: event, metadata: { "event_kind" => event.event_kind })
      end
    end

    def scoped_record!(scope)
      case scope
      when SupportCase then @workspace.support_cases.find(scope.id)
      when Account then @workspace.accounts.find(scope.id)
      when HealthScorecard then @workspace.health_scorecard.tap do |scorecard|
        raise InvalidCommand, "Tasks must belong to this Workspace scorecard." unless scorecard&.id == scope.id
      end
      else raise InvalidCommand, "Tasks must belong to a case, account, or scorecard."
      end
    end

    def same_scope?(task, scope)
      task.scope_kind == scope_kind(scope) && task.public_send(scope_association(scope)) == scope
    end

    def scope_kind(scope)
      case scope
      when SupportCase then "support_case"
      when Account then "account"
      when HealthScorecard then "health_scorecard"
      end
    end

    def scope_association(scope)
      case scope
      when SupportCase then :support_case
      when Account then :account
      when HealthScorecard then :health_scorecard
      end
    end

    def lock_scope!(scope)
      CrewScopeLock.acquire!(workspace: @workspace, scope:)
    end

    def required_body(value, message)
      value.to_s.strip.presence || raise(InvalidCommand, message)
    end

    def authorize_write!
      raise Current::RoleAccessDenied unless @membership&.can_write?
    end

    def authorize_review!
      raise Current::RoleAccessDenied unless @membership.can_manage_work?
    end
end
