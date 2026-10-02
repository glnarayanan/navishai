class CorpusAnalysisJob < ApplicationJob
  def perform(id)
    analysis = CorpusAnalysis.find_by(id:)
    return unless analysis

    analysis.corpus.with_lock do
      analysis.lock!
      return unless analysis.state == "queued"

      membership = analysis.workspace.memberships.find_by!(user: analysis.requested_by)
      analysis.corpus.authorize_writer!(membership)
      summary = CorpusDiscovery.call(analysis)
      analysis.update!(summary:, state: "complete")
    end
  rescue StandardError => error
    message = case error
    when CorpusIntake::Invalid then error.message
    when Current::RoleAccessDenied, ActiveRecord::RecordNotFound then "Workspace access changed; request a new analysis."
    else "Local analysis failed; no proposals saved. Request a new analysis or ask your operator to check the worker."
    end
    Rails.logger.error("Corpus analysis #{id} failed (#{error.class})")
    CorpusAnalysis.where(id:, state: "queued").update_all(state: "failed", error: message)
  end
end
