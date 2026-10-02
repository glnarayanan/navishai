class CorpusAnalysisInput < ImmutableRecord
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :corpus_analysis
  belongs_to :corpus_item
end
