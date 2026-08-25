class ExecutionRecovery
  class InvalidAction < StandardError; end

  def self.request!(workspace:, membership:, task:, request_key:, client: nil)
    new(workspace:, membership:).request!(task:, request_key:, client:)
  end

  def self.reconcile!(workspace:, membership:, task:, run:, client: nil)
    new(workspace:, membership:).reconcile!(task:, run:, client:)
  end

  def initialize(workspace:, membership:)
    @workspace = workspace
    @membership = workspace.memberships.find(membership.id)
  end

  def request!(task:, request_key:, client:)
    authorize!
    task = @workspace.crew_tasks.find(task.id)
    run = ExecutionRun.transaction do
      task.lock!
      raise InvalidAction, "Start the task before requesting a run." unless task.in_progress?

      existing = @workspace.execution_runs.find_by(request_key: request_key.to_s)
      if existing
        raise InvalidAction, "That request belongs to another task." unless existing.crew_task_id == task.id
        existing
      else
        if task.execution_runs.active.exists?
          raise InvalidAction, "This task already has an active run."
        end
        created = ExecutionLedger.new(workspace: @workspace).prepare!(task:, request_key:)
        AuditEvent.record!(
          action: "execution.run_requested", source: :web, workspace: @workspace,
          actor: @membership.user, subject: created
        )
        created
      end
    end
    ExecutionLedger.new(workspace: @workspace).admit!(run:, client:)
  rescue ExecutionLedger::InvalidRun => error
    raise InvalidAction, error.message
  end

  def reconcile!(task:, run:, client:)
    authorize!
    task = @workspace.crew_tasks.find(task.id)
    run = @workspace.execution_runs.find(run.id)
    raise InvalidAction, "Run does not belong to this task." unless run.crew_task_id == task.id

    ExecutionRun.transaction do
      run.lock!
      raise InvalidAction, "Only an unconfirmed admission can be reconciled." unless run.admitting?
      AuditEvent.record!(
        action: "execution.run_reconciled", source: :web, workspace: @workspace,
        actor: @membership.user, subject: run
      )
    end
    ExecutionLedger.new(workspace: @workspace).admit!(run:, client:)
  end

  private
    def authorize!
      raise Current::RoleAccessDenied, "role cannot perform this action" unless @membership.can_write?
    end
end
