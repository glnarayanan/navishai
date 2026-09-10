class ReliabilityRecovery
  class InvalidAction < StandardError; end

  def self.reconcile_run!(workspace:, membership:, run:, client: nil)
    actor = manager!(workspace, membership)
    current = workspace.execution_runs.find(run.id)
    ExecutionRecovery.reconcile!(
      workspace:, membership: actor, task: current.crew_task, run: current, client:
    )
  rescue ExecutionRecovery::InvalidAction => error
    raise InvalidAction, error.message
  end

  def self.retry_run!(workspace:, membership:, run:, client: nil)
    actor = manager!(workspace, membership)
    current = workspace.execution_runs.includes(:crew_task).find(run.id)
    unless current.failed? && current.retryable?
      raise InvalidAction, "Only a definite retryable failure can start another run."
    end
    raise InvalidAction, "The task is no longer in progress." unless current.crew_task.in_progress?

    if current.selected_personal_account_key
      unless current.requested_by_membership_id == actor.id
        raise InvalidAction, "Only the original requester can retry a run using their personal AI account."
      end
      account = PersonalProviderAccount.find_by(workspace:, membership: actor, account_key: current.selected_personal_account_key)
      raise InvalidAction, "The original personal AI account is unavailable. Reconnect it before retrying." unless account&.usable?
    end

    ExecutionRecovery.request!(
      workspace:, membership: actor, task: current.crew_task,
      request_key: "operations:retry:#{current.run_key}", client:, personal_account_id: account&.id
    )
  rescue ExecutionRecovery::InvalidAction => error
    raise InvalidAction, error.message
  end

  def self.reconstruct_memory!(workspace:, membership:)
    actor = manager!(workspace, membership)
    MemoryPortability.reconstruct_index!(workspace:, membership: actor)
  end

  def self.manager!(workspace, membership)
    workspace.memberships.find(membership.id).tap do |actor|
      raise Current::RoleAccessDenied unless actor.can_manage_work?
    end
  end
  private_class_method :manager!
end
