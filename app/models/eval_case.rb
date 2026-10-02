class EvalCase < ImmutableRecord
  class Invalid < StandardError; end
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :scenario_version
  belongs_to :scenario_review
  belongs_to :compiled_by, class_name: "User"
  has_many :eval_case_checks

  def self.matching_trace(item)
    joins(:scenario_version).joins(<<~SQL.squish).where("replay_trace.id = ? AND replay_source.kind = 'traces' AND replay_source.expires_at > ?", item.id, Time.current).where(<<~SQL.squish)
      INNER JOIN corpus_items replay_trace
        ON replay_trace.corpus_id = eval_cases.corpus_id AND replay_trace.workspace_id = eval_cases.workspace_id
      INNER JOIN source_snapshots replay_snapshot ON replay_snapshot.id = replay_trace.source_snapshot_id
      INNER JOIN sources replay_source ON replay_source.id = replay_snapshot.source_id
    SQL
      jsonb_build_object(
        'situation', scenario_versions.situation,
        'known_facts', scenario_versions.known_facts,
        'knowledge', COALESCE((
          SELECT jsonb_agg(jsonb_build_object(
            'reference', 'corpus-item-' || scenario_evidence.corpus_item_id::text,
            'content', scenario_evidence.excerpt) ORDER BY scenario_evidence.id)
          FROM scenario_evidence
          WHERE scenario_evidence.scenario_version_id = scenario_versions.id
            AND scenario_evidence.kind = 'knowledge'
        ), '[]'::jsonb)
      ) = replay_trace.context -> 'support_trace' -> 'input'
    SQL
  end

  def eligible!
    version = scenario_version.reload
    expected = contract.flat_map { |kind, statements| statements.each_index.map { |index| [ kind, index ] } }.sort
    actual = eval_case_checks.pluck(:requirement_kind, :requirement_index).sort
    raise Invalid, "This case needs the current approved scenario version, complete checks and unexpired, current document evidence." unless version.scenario.current_version_id == version.id && version.approved? && !version.expired? && !version.stale? && !corpus.eval_definitions_expired? && actual == expected
  end
end
