class ModelFailureMatchingJob < ApplicationJob
  queue_as :evaluations
  self.enqueue_after_transaction_commit = true

  def perform(id)
    request = ModelFailureMatching.find_by(id:)
    return unless request
    claimed = request.corpus.with_lock do
      request.lock!
      next false unless request.state == "queued"
      request.update!(state: "running", started_at: Time.current)
      request.authorize_execution!
    end
    return unless claimed
    result = ModelFailureMatcher.call(request)
    request.corpus.with_lock do
      return unless request.authorize_execution!
      request.create_model_failure_matching_result!(workspace: request.workspace, corpus: request.corpus, result:, created_at: Time.current)
      request.update!(state: "complete", finished_at: Time.current)
      AuditEvent.record!(action: "trace.matching_completed", source: :job, workspace: request.workspace, actor_kind: "system", subject: request)
    end
  rescue StandardError => error
    Rails.logger.error("Model failure matching #{id} interrupted (#{error.class})")
    ModelFailureMatching.where(id:, state: %w[queued running]).update_all(state: "interrupted", finished_at: Time.current,
      error: "Matching stopped because access, source evidence, eligible versions or worker state changed. Remote outcome/cost may be unknown; this attempt will not retry.")
  end
end
