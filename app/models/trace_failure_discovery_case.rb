class TraceFailureDiscoveryCase < ImmutableRecord
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :trace_failure_discovery
  belongs_to :eval_case
end
