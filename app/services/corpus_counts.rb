# Per-corpus totals for overview tables. Counts only; no titles or content leave the corpus.
class CorpusCounts
  Row = Data.define(:sources, :suites, :runs, :last_run_at)

  def self.call(corpora)
    ids = corpora.map(&:id)
    sources = Source.where(corpus_id: ids).where("expires_at > ?", Time.current).group(:corpus_id).count
    suites = EvalSuite.where(corpus_id: ids).group(:corpus_id).count
    runs = EvaluationRun.where(corpus_id: ids).group(:corpus_id).count
    last_runs = EvaluationRun.where(corpus_id: ids).group(:corpus_id).maximum(:created_at)
    ids.index_with do |id|
      Row.new(sources: sources.fetch(id, 0), suites: suites.fetch(id, 0), runs: runs.fetch(id, 0), last_run_at: last_runs[id])
    end
  end
end
