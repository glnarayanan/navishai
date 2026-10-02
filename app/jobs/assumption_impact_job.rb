class AssumptionImpactJob < ApplicationJob
  queue_as :evaluations
  self.enqueue_after_transaction_commit = true

  def perform(id)
    impact = AssumptionImpact.find_by(id:)
    return unless impact
    claimed = impact.corpus.with_lock do
      impact.lock!
      next false unless impact.state == "queued"
      impact.update!(state: "running", started_at: Time.current)
      impact.authorize_processing!
      true
    end
    return unless claimed
    result = AssumptionChangeAnalysis.call(impact)
    impact.corpus.with_lock do
      return unless impact.authorize_processing!
      impact.create_assumption_impact_result!(workspace: impact.workspace, corpus: impact.corpus, result:, created_at: Time.current)
      impact.update!(state: "complete", finished_at: Time.current)
      AuditEvent.record!(action: "assumption_impact.completed", source: :job, workspace: impact.workspace, actor_kind: "system", subject: impact)
    end
  rescue StandardError => error
    Rails.logger.error("Assumption impact #{id} interrupted (#{error.class})")
    AssumptionImpact.transaction do
      attempt = AssumptionImpact.lock.find_by(id:, state: %w[queued running])
      if attempt
        attempt.update!(state: "interrupted", finished_at: Time.current,
          error: "Execution stopped. Access, source, assumptions or endpoint approval changed. Remote outcome/cost may be unknown; this attempt will not retry. Review a fresh preview before another deliberate request.")
        AuditEvent.record!(action: "assumption_impact.interrupted", source: :job, workspace: attempt.workspace, actor_kind: "system", subject: attempt)
      end
    end
  end
end
