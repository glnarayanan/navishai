class CorpusAnalysisJob < ApplicationJob
  self.enqueue_after_transaction_commit = true

  def perform(id)
    analysis = CorpusAnalysis.find_by(id:)
    return unless analysis

    claimed = analysis.corpus.with_lock do
      analysis.lock!
      next false unless analysis.state == "queued"
      analysis.update!(state: "running", started_at: Time.current)
      analysis.authorize_processing!
      true
    end
    return unless claimed
    response = analysis.batch? ? BatchCorpusDiscovery.execute(analysis) : ModelCorpusDiscovery.call(analysis) if analysis.model?
    analysis.corpus.with_lock do
      return unless analysis.authorize_processing!
      summary = analysis.model? ? ModelCorpusDiscovery.persist!(analysis, response) : CorpusDiscovery.call(analysis)
      analysis.authorize_processing!
      analysis.update!(summary:, state: "complete", finished_at: Time.current)
      AuditEvent.record!(action: "corpus.analysis_completed", source: :job, workspace: analysis.workspace, actor_kind: "system", subject: analysis)
    end
  rescue StandardError => error
    message = case error
    when CorpusIntake::Invalid then error.message
    when Current::RoleAccessDenied, ActiveRecord::RecordNotFound then "Workspace access changed; request a new analysis."
    else "Analysis stopped; no proposals saved. Remote outcome/cost may be unknown. No automatic retry; request a new analysis deliberately."
    end
    Rails.logger.error("Corpus analysis #{id} failed (#{error.class})")
    CorpusAnalysis.where(id:, state: %w[queued running]).update_all(state: "failed", error: message, finished_at: Time.current)
  end
end
