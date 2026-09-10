class KnowledgeSearch
  Result = Data.define(:source, :version, :rank, :excerpt, :citation_uri) do
    def stale?
      source.stale?
    end

    def deleted?
      source.deleted?
    end
  end

  def self.search(workspace:, query:, limit: 25, support_case: nil)
    normalized = query.to_s.squish
    return [] if normalized.blank?

    relation = workspace.knowledge_source_versions
      .joins(:knowledge_source)
      .preload(:knowledge_source)
      .merge(KnowledgeSource.active)
      .where(knowledge_source_id: KnowledgeApplicabilityScope.new(workspace:, support_case:).sources.select(:id))
      .where("knowledge_source_versions.id = knowledge_sources.current_version_id")
      .where(
        "search_document @@ websearch_to_tsquery('english', :query) OR " \
        "to_tsvector('english', knowledge_sources.title) @@ websearch_to_tsquery('english', :query)",
        query: normalized
      )
      .select(
        "knowledge_source_versions.*",
        KnowledgeSourceVersion.sanitize_sql_array(
          [
            "ts_rank_cd(search_document, websearch_to_tsquery('english', ?)) + " \
            "ts_rank_cd(to_tsvector('english', knowledge_sources.title), websearch_to_tsquery('english', ?)) AS search_rank",
            normalized, normalized
          ]
        )
      )
      .order(Arel.sql("search_rank DESC"), :id)
      .limit(limit)

    relation.map do |version|
      source = version.knowledge_source
      Result.new(
        source:, version:, rank: version.read_attribute("search_rank").to_f,
        excerpt: excerpt(version.content, normalized), citation_uri: source.citation_uri(version)
      )
    end
  end

  def self.excerpt(content, query)
    terms = query.downcase.scan(/[[:alnum:]]+/).reject { |term| term.length < 2 }
    position = terms.filter_map { |term| content.downcase.index(term) }.min || 0
    start = [ position - 90, 0 ].max
    text = content.slice(start, 260).to_s.squish
    text = "…#{text}" if start.positive?
    text = "#{text}…" if start + 260 < content.length
    text
  end
  private_class_method :excerpt
end
