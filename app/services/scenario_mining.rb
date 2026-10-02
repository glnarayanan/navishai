class ScenarioMining
  DRAFT_METHOD = "literal-source-review-v2"
  REVIEW_CUES = {
    "symptom" => [ /\b(?:cannot|unable|fails?|error|symptom|stopped|problem)\b/i, "What is the reported symptom, and what issue does evidence support?" ],
    "diagnosis" => [ /\b(?:cause|caused|diagnosis|suspect|probably|might|defect|bug)\b/i, "Is this diagnosis supported, or only a guess?" ],
    "diagnostics" => [ /\b(?:ask|request|collect|verify|inspect|reproduce|logs?|metadata|test)\b/i, "Which diagnostics occurred, and which should be required?" ],
    "guidance" => [ /\b(?:contradict\w*|conflict\w*|however|instead|ignore|do not|must not)\b/i, "Does other guidance disagree? Check both sources before choosing a rule." ],
    "closure" => [ /\b(?:resolved|fixed|closed|solved|resolution)\b/i, "Was resolution proved, partial, or only claimed?" ],
    "recurrence" => [ /\b(?:reopen\w*|still|again|persists?|not resolved|not fixed)\b/i, "Does later evidence challenge closure? A mention alone does not prove false resolution." ],
    "entitlement" => [ /\b(?:plan|enterprise|starter|permission\w*|admin|entitl\w*|suspend\w*|policy)\b/i, "Which account or policy branch applies? Verify entitlement with company evidence." ],
    "workaround" => [ /\b(?:workaround|temporary|bypass)\b/i, "Is this a workaround rather than a permanent resolution?" ],
    "escalation" => [ /\b(?:escalat\w*|engineering|handoff|incident)\b/i, "What evidence and conditions justify escalation?" ]
  }.freeze

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
        label = member.issue_cluster.label
        selection_reason = nominating ? "Expert nominated this fixed record for review: #{reason.strip}" : member.selection_reason
        if label.length > 500
          label = label.first(500)
          selection_reason += " Draft label shortened to 500 characters; inspect the full issue family before review."
        end
        candidate = model_candidates&.find { |entry| entry.fetch("reference") == "corpus-item-#{item.id}" }
        notes = candidate ? {} : draft_notes(item)
        opening = notes["opening"]
        values = { title: item.title, situation: opening ? item.content[opening[0], opening[1]] : "Expert: define the customer's starting situation from this source.",
          taxonomy_label: label, importance: member.signals.include?("reported critical impact") ? "critical" : member.signals.any? ? "high" : "normal",
          known_facts: {}, hidden_facts: {}, requirements: }.stringify_keys
        values = candidate.fetch("scenario").merge("taxonomy_label" => label) if candidate
        version = scenario.scenario_versions.create!(values.merge(workspace: analysis.workspace, corpus: analysis.corpus,
          created_by: membership.user, number: 1, origin: "mined", selection_reason:, draft_notes: notes, created_at: Time.current))
        if candidate
          quotes = ModelCorpusDiscovery.evidence_for(candidate, cluster: member.issue_cluster.signals, sources: source_items.transform_values(&:content))
          quotes.each do |quote|
            version.scenario_evidence.create!(workspace: analysis.workspace, corpus: analysis.corpus,
              corpus_item: source_items.fetch(quote.fetch("reference")), kind: "expectation", excerpt: quote.fetch("excerpt"))
          end
        else
          start, length = notes.fetch("evidence")
          version.scenario_evidence.create!(workspace: analysis.workspace, corpus: analysis.corpus, corpus_item: item, kind: "expectation", excerpt: item.content[start, length])
        end
        scenario.update!(current_version: version)
        AuditEvent.record!(action: "scenario.mined", source: :web, workspace: analysis.workspace, actor: membership.user, subject: version, metadata: { version: 1 })
        scenario
      end
    end
  end

  def self.draft_notes(item)
    text = item.content
    opening = text.match(/\S[^\n]*(?:\n(?!\s*\n)[^\n]*)*/)
    sentence = opening && opening[0].match(/\A.*?[.!?](?=\s|\z)/m)
    opening_length = opening && [ sentence ? sentence[0].length : opening[0].length, 2000 ].min
    spans = REVIEW_CUES.flat_map do |kind, (pattern, _question)|
      first = last = nil
      text.to_enum(:scan, pattern).each do
        match = Regexp.last_match
        start = [ match.begin(0) - 80, 0 ].max
        span = { "kind" => kind, "start" => start, "length" => [ 240, text.length - start ].min }
        first ||= span
        last = span
      end
      [ first, last ].compact.uniq
    end
    length = [ 4000, text.length ].min
    starts = [ 0 ] + spans.flat_map { |span| [ span.fetch("start"), span.fetch("start") + span.fetch("length") - length ] }
    start = starts.map { |offset| offset.clamp(0, text.length - length) }.uniq.max_by do |offset|
      covered = spans.select { |span| span.fetch("start") >= offset && span.fetch("start") + span.fetch("length") <= offset + length }
      [ covered.map { |span| span.fetch("kind") }.uniq.size, covered.size, -offset ]
    end
    { "method" => DRAFT_METHOD, "source_length" => text.length, "context_omitted" => item.context.present?,
      "opening" => opening && [ opening.begin(0), opening_length ], "evidence" => [ start, length ], "review_spans" => spans }
  end
end
