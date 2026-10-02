class TraceFailureDiscoveryInput < ImmutableRecord
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :trace_failure_discovery
  belongs_to :corpus_item
end
