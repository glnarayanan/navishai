require "test_helper"
require_relative "../test_helpers/model_discovery_test_helper"

class ModelDiscoveryDeliveryTest < ActiveSupport::TestCase
  include ModelDiscoveryTestHelper
  self.use_transactional_tests = false
  setup { @existing_audit_ids = AuditEvent.ids }
  teardown do
    @corpus&.delete
    ActiveRecord::Base.connection.disable_referential_integrity { AuditEvent.where.not(id: @existing_audit_ids).delete_all }
  end

  test "concurrent delivery sends once outside locks and purge discards the returning response" do
    build_discovery_corpus
    entered, release = Queue.new, Queue.new
    calls = 0
    worker = nil
    with_corpus_approval do
      analysis = request_model_analysis
      response = discovery_response
      with_test_method(ModelCorpusDiscovery, :call, ->(*) { calls += 1; entered << true; release.pop; response }) do
        worker = Thread.new { ActiveRecord::Base.connection_pool.with_connection { CorpusAnalysisJob.perform_now(analysis.id) } }
        Timeout.timeout(5) { entered.pop }
        CorpusAnalysisJob.perform_now(analysis.id)
        ActiveRecord::Base.transaction do
          ActiveRecord::Base.connection.execute("SET LOCAL lock_timeout = '1s'")
          @corpus.lock!
          @membership.lock!
          SourcePurge.call(source: @snapshot.source, membership: @membership)
        end
        release << true
        worker.value
      end
      assert_equal 1, calls
      assert_not CorpusAnalysis.exists?(analysis.id)
      assert_equal 0, CorpusAnalysisResult.where(corpus: @corpus).count
      assert_empty IssueCluster.where(corpus: @corpus)
    end
  ensure
    release << true if release
    worker&.value
  end
end
