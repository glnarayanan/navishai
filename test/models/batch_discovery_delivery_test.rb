require "test_helper"
require_relative "../test_helpers/batch_discovery_test_helper"

class BatchDiscoveryDeliveryTest < ActiveSupport::TestCase
  include BatchDiscoveryTestHelper
  self.use_transactional_tests = false
  setup { @existing_audit_ids = AuditEvent.ids }
  teardown do
    @corpus&.delete
    ActiveRecord::Base.connection.disable_referential_integrity { AuditEvent.where.not(id: @existing_audit_ids).delete_all }
  end

  test "duplicate delivery cannot claim parent again and network waits release corpus and membership locks" do
    build_batch_corpus
    entered, release = Queue.new, Queue.new
    calls = []
    worker = nil
    with_batch_responses(calls:, after_call: ->(number) { entered << true; release.pop if number == 1 }) do
      analysis = request_batch_analysis
      worker = Thread.new { ActiveRecord::Base.connection_pool.with_connection { CorpusAnalysisJob.perform_now(analysis.id) } }
      Timeout.timeout(5) { entered.pop }
      CorpusAnalysisJob.perform_now(analysis.id)
      ActiveRecord::Base.transaction do
        ActiveRecord::Base.connection.execute("SET LOCAL lock_timeout = '1s'")
        @corpus.lock!
        @membership.lock!
        @snapshot.source.update!(expires_at: 1.minute.ago)
      end
      release << true
      worker.value
      assert_equal 1, calls.size
      assert_equal "failed", analysis.reload.state
      assert_equal %w[error queued queued], analysis.corpus_discovery_batches.order(:position).pluck(:state)
      assert_empty analysis.issue_clusters
      assert_nil analysis.corpus_analysis_result
    end
  ensure
    release << true if release
    worker&.value
  end
end
