class ExecutionRecovery
  class InvalidAction < StandardError; end

  def self.request!(workspace:, membership:, task:, request_key:, client: nil, personal_account_id: nil)
    new(workspace:, membership:).request!(task:, request_key:, client:, personal_account_id:)
  end

  def self.reconcile!(workspace:, membership:, task:, run:, client: nil)
    new(workspace:, membership:).reconcile!(task:, run:, client:)
  end

  def initialize(workspace:, membership:)
    @workspace = workspace
    @membership = workspace.memberships.find(membership.id)
  end

  def request!(task:, request_key:, client:, personal_account_id: nil)
    authorize!
    task = @workspace.crew_tasks.find(task.id)
    personal_account = PersonalProviderAccount.find_by!(workspace: @workspace, membership: @membership, id: personal_account_id) if personal_account_id.present?
    run = ExecutionRun.transaction do
      task.lock!
      raise InvalidAction, "Start the task before requesting a run." unless task.in_progress?

      existing = @workspace.execution_runs.find_by(request_key: request_key.to_s)
      if existing
        raise InvalidAction, "That request belongs to another task." unless existing.crew_task_id == task.id
        unless existing.requested_by_membership_id == @membership.id && existing.selected_personal_account_key == personal_account&.account_key
          raise InvalidAction, "That request belongs to another requester or AI account."
        end
        existing
      else
        if task.execution_runs.active.exists?
          raise InvalidAction, "This task already has an active run."
        end
        created = ExecutionLedger.new(workspace: @workspace).prepare!(task:, request_key:, membership: @membership, personal_account:)
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
  rescue ExecutionLedger::InvalidRun => error
    raise InvalidAction, error.message
  end

  private
    def authorize!
      raise Current::RoleAccessDenied, "role cannot perform this action" unless @membership.can_write?
    end
end
