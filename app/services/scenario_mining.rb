class ScenarioMining
  def self.call(analysis:, membership:)
    analysis.corpus.with_lock do
      analysis.corpus.authorize_writer!(membership)
      analysis.reload
      raise Scenario::Invalid, "Finish an unexpired analysis first." unless analysis.state == "complete" && !analysis.expired?
      members = ClusterMember.selected.where(issue_cluster: analysis.issue_clusters).includes(:issue_cluster, :corpus_item)
      members.map do |member|
        existing = analysis.corpus.scenarios.find_by(cluster_member: member)
        next existing if existing

        item = member.corpus_item
        scenario = analysis.corpus.scenarios.create!(workspace: analysis.workspace, corpus_item: item, cluster_member: member)
        requirements = ScenarioVersion::REQUIREMENT_TYPES.index_with { [] }
        requirements["actions"] = item.content.split(/(?<=[.!?])\s+/).select { |sentence| sentence.match?(/\b(ask|request|collect|verify|reproduce)\b/i) }.first(10).map { |sentence| sentence.first(2000) }
        version = scenario.scenario_versions.create!(workspace: analysis.workspace, corpus: analysis.corpus,
          created_by: membership.user, number: 1, origin: "mined", title: item.title, situation: item.title,
          taxonomy_label: member.issue_cluster.label, importance: member.signals.include?("reported critical impact") ? "critical" : member.signals.any? ? "high" : "normal",
          known_facts: item.context, hidden_facts: {}, requirements:, selection_reason: member.selection_reason, created_at: Time.current)
        version.scenario_evidence.create!(workspace: analysis.workspace, corpus: analysis.corpus, corpus_item: item, kind: "expectation", excerpt: item.content.first(4000))
        scenario.update!(current_version: version)
        AuditEvent.record!(action: "scenario.mined", source: :web, workspace: analysis.workspace, actor: membership.user, subject: version, metadata: { version: 1 })
        scenario
      end
    end
  end
end
