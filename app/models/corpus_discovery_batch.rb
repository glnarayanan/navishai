class CorpusDiscoveryBatch < ApplicationRecord
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :corpus_analysis
  attr_readonly :workspace_id, :corpus_id, :corpus_analysis_id, :request_key, :phase, :position, :input_refs, :input_digest, :created_at
  validates :state, inclusion: { in: %w[queued running proposal abstain error] }
end
