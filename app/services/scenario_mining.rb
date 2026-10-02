class ScenarioMining
  def self.call(analysis:, membership:)
    analysis.corpus.with_lock do
      analysis.corpus.authorize_writer!(membership)
      analysis.reload
      raise Scenario::Invalid, "Finish an unexpired analysis first." unless analysis.state == "complete" && !analysis.expired?
      members = ClusterMember.selected.where(issue_cluster: analysis.issue_clusters).includes(:issue_cluster, :corpus_item)
      model_candidates = analysis.model? ? analysis.corpus_analysis_result.result.fetch("candidates", []) : nil
      source_items = analysis.corpus_items.index_by { |item| "corpus-item-#{item.id}" } if model_candidates
      members.map do |member|
        existing = analysis.corpus.scenarios.find_by(cluster_member: member)
        next existing if existing

        item = member.corpus_item
        scenario = analysis.corpus.scenarios.create!(workspace: analysis.workspace, corpus_item: item, cluster_member: member)
        requirements = ScenarioVersion::REQUIREMENT_TYPES.index_with { [] }
        requirements["actions"] = item.content.split(/(?<=[.!?])\s+/).select { |sentence| sentence.match?(/\b(ask|request|collect|verify|reproduce)\b/i) }.first(10).map { |sentence| sentence.first(2000) }
        values = { title: item.title, situation: item.title,
          taxonomy_label: member.issue_cluster.label, importance: member.signals.include?("reported critical impact") ? "critical" : member.signals.any? ? "high" : "normal",
          known_facts: item.context, hidden_facts: {}, requirements: }.stringify_keys
        candidate = model_candidates&.find { |entry| entry.fetch("reference") == "corpus-item-#{item.id}" }
        values = candidate.fetch("scenario").merge("taxonomy_label" => member.issue_cluster.label) if candidate
        version = scenario.scenario_versions.create!(values.merge(workspace: analysis.workspace, corpus: analysis.corpus,
          created_by: membership.user, number: 1, origin: "mined", selection_reason: member.selection_reason, created_at: Time.current))
        if candidate
          quotes = ModelCorpusDiscovery.evidence_for(candidate, cluster: member.issue_cluster.signals, sources: source_items.transform_values(&:content))
          quotes.each do |quote|
            version.scenario_evidence.create!(workspace: analysis.workspace, corpus: analysis.corpus,
              corpus_item: source_items.fetch(quote.fetch("reference")), kind: "expectation", excerpt: quote.fetch("excerpt"))
          end
        else
          version.scenario_evidence.create!(workspace: analysis.workspace, corpus: analysis.corpus, corpus_item: item, kind: "expectation", excerpt: item.content.first(4000))
        end
        scenario.update!(current_version: version)
        AuditEvent.record!(action: "scenario.mined", source: :web, workspace: analysis.workspace, actor: membership.user, subject: version, metadata: { version: 1 })
        scenario
      end
    end
  end
end
