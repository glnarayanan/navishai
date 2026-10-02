class TraceFailureDiscoveryJob < ApplicationJob
  queue_as :evaluations
  self.enqueue_after_transaction_commit = true

  def perform(id)
    discovery = TraceFailureDiscovery.find_by(id:)
    return unless discovery
    claimed = discovery.corpus.with_lock do
      discovery.lock!
      next false unless discovery.state == "queued"
      discovery.update!(state: "running", started_at: Time.current)
      discovery.authorize_processing!
    end
    return unless claimed
    result = TraceFailureDiscoveryProtocol.call(discovery)
    discovery.corpus.with_lock do
      return unless discovery.authorize_processing!
      discovery.create_trace_failure_discovery_result!(workspace: discovery.workspace, corpus: discovery.corpus, result_content: result, created_at: Time.current)
      discovery.update!(state: "complete", finished_at: Time.current)
      AuditEvent.record!(action: "trace.discovery_completed", source: :job, workspace: discovery.workspace, actor_kind: "system", subject: discovery)
    end
  rescue StandardError => error
    Rails.logger.error("Trace failure discovery #{id} interrupted (#{error.class})")
    if discovery
      discovery.corpus.with_lock do
        record = TraceFailureDiscovery.lock.find_by(id:, state: %w[queued running])
        if record
          record.update!(state: "interrupted", finished_at: Time.current, error: "Execution stopped after access, evidence or worker state changed. Remote outcome/cost may be unknown. No retained findings or automatic retry.")
          AuditEvent.record!(action: "trace.discovery_interrupted", source: :job, workspace: record.workspace, actor_kind: "system", subject: record)
        end
      end
    end
  end
end
