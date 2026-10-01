class CorpusAnalysisJob < ApplicationJob
  self.enqueue_after_transaction_commit = true

  def perform(id)
    analysis = CorpusAnalysis.find_by(id:)
    return unless analysis

    claimed = analysis.corpus.with_lock do
      analysis.lock!
      next false unless analysis.state == "queued"
      analysis.update!(state: "running", started_at: Time.current)
      authorize!(analysis)
      true
    end
    return unless claimed
    response = ModelCorpusDiscovery.call(analysis) if analysis.model?
    analysis.corpus.with_lock do
      return unless authorize!(analysis)
      summary = analysis.model? ? ModelCorpusDiscovery.persist!(analysis, response) : CorpusDiscovery.call(analysis)
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

  private
    def authorize!(analysis)
      analysis.reload
      return false unless analysis.state == "running"
      membership = analysis.workspace.memberships.find_by!(user: analysis.requested_by)
      analysis.corpus.authorize_writer!(membership)
      raise CorpusIntake::Invalid, "Source inputs expired; request a new analysis." if analysis.expired?
      if analysis.model?
        raise CorpusIntake::Invalid, "Company documentation changed; request a new analysis using current evidence." if analysis.stale?
        raise CorpusIntake::Invalid, "Invalid fixed model settings." unless ModelGateway.valid_configuration?(analysis.configuration)
        input = ModelCorpusDiscovery.input(analysis.corpus_items.includes(source_snapshot: :source).order(:id).to_a)
        raise CorpusIntake::Invalid, "Fixed corpus inputs changed; no proposals saved." unless ModelCorpusDiscovery.digest(input) == analysis.input_digest
        EvaluationHttp.validate!(analysis.configuration.slice("endpoint"), workspace_id: analysis.workspace_id, purpose: :corpus)
      else
        raise CorpusIntake::Invalid, "Unsupported discovery method." unless analysis.processing_method == CorpusAnalysis::METHOD
      end
      true
    end
end
