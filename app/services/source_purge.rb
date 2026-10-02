class SourcePurge
  def self.call(source:, membership: nil)
    source.corpus.with_lock do
      source.lock!
      if membership
        source.corpus.authorize_writer!(membership, manage: true)
      else
        return if source.expires_at > Time.current
      end
      AuditEvent.record!(action: "source.deleted", source: membership ? :web : :job,
        workspace: source.workspace, actor: membership&.user, actor_kind: "system", subject: source)
      TraceFailureDiscovery.where(corpus: source.corpus).delete_all
      source.corpus.evaluation_runs.delete_all(:delete_all)
      source.corpus.evaluation_targets.delete_all(:delete_all)
      AssumptionImpact.where(corpus: source.corpus).delete_all
      source.corpus.scenarios.delete_all(:delete_all)
      source.corpus.corpus_analyses.delete_all(:delete_all)
      source.corpus.graders.delete_all(:delete_all)
      source.delete
    end
  end
end
