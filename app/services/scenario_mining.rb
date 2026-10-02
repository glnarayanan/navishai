class ScenarioMining
  def self.call(analysis:, membership:, member_id: nil, reason: nil)
    analysis.corpus.with_lock do
      analysis.corpus.authorize_writer!(membership)
      analysis.reload
      raise Scenario::Invalid, "Finish an unexpired analysis first." unless analysis.state == "complete" && !analysis.expired?
      nominating = !member_id.nil?
      members = ClusterMember.where(issue_cluster: analysis.issue_clusters).includes(:issue_cluster)
      if nominating
        raise Scenario::Invalid, "Explain why this record needs a scenario (1–2000 characters, with no null bytes)." unless reason.is_a?(String) && reason.strip.present? && reason.length <= 2000 && !reason.include?("\0")
        members = [ members.find(member_id) ]
      else
        members = members.selected.to_a
      end
      model_candidates = analysis.model? && !nominating ? analysis.corpus_analysis_result.result.fetch("candidates", []) : nil
      item_ids = members.map(&:corpus_item_id)
      item_ids += model_candidates.flat_map { |candidate| candidate.fetch("evidence_links").map { |link| link.fetch("reference").delete_prefix("corpus-item-") } } if model_candidates
      source_items = analysis.fixed_inputs(item_ids:).index_by { |item| "corpus-item-#{item.id}" }
      members.map do |member|
        existing = analysis.corpus.scenarios.find_by(cluster_member: member)
        next existing if existing

        item = source_items.fetch("corpus-item-#{member.corpus_item_id}")
        scenario = analysis.corpus.scenarios.create!(workspace: analysis.workspace, corpus_item: item, cluster_member: member)
        requirements = ScenarioVersion::REQUIREMENT_TYPES.index_with { [] }
        requirements["actions"] = item.content.split(/(?<=[.!?])\s+/).select { |sentence| sentence.match?(/\b(ask|request|collect|verify|reproduce)\b/i) }.first(10).map { |sentence| sentence.first(2000) }
        label = member.issue_cluster.label
        selection_reason = nominating ? "Expert nominated this fixed record for review: #{reason.strip}" : member.selection_reason
        if label.length > 500
          label = label.first(500)
          selection_reason += " Draft label shortened to 500 characters; inspect the full issue family before review."
        end
        values = { title: item.title, situation: item.title,
          taxonomy_label: label, importance: member.signals.include?("reported critical impact") ? "critical" : member.signals.any? ? "high" : "normal",
          known_facts: item.context, hidden_facts: {}, requirements: }.stringify_keys
        candidate = model_candidates&.find { |entry| entry.fetch("reference") == "corpus-item-#{item.id}" }
        values = candidate.fetch("scenario").merge("taxonomy_label" => label) if candidate
        version = scenario.scenario_versions.create!(values.merge(workspace: analysis.workspace, corpus: analysis.corpus,
          created_by: membership.user, number: 1, origin: "mined", selection_reason:, created_at: Time.current))
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
