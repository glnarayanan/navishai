require "test_helper"
require_relative "../test_helpers/scenario_proposal_test_helper"

class ScenarioProposalDeliveryTest < ActiveSupport::TestCase
  include ScenarioProposalTestHelper
  self.use_transactional_tests = false
  setup { @existing_audit_ids = AuditEvent.ids }
  teardown do
    @corpus&.delete
    ActiveRecord::Base.connection.disable_referential_integrity { AuditEvent.where.not(id: @existing_audit_ids).delete_all }
  end

  test "concurrent delivery sends once outside locks and a source purge discards the returning copy" do
    build_proposal_scenario
    entered, release = Queue.new, Queue.new
    calls = 0
    worker = nil
    with_scenario_approval do
      proposal = request_proposal
      response = proposal_response
      with_test_method(ScenarioExtractor, :call, ->(*) { calls += 1; entered << true; release.pop; response }) do
        worker = Thread.new { ActiveRecord::Base.connection_pool.with_connection { ScenarioProposalJob.perform_now(proposal.id) } }
        Timeout.timeout(5) { entered.pop }
        ScenarioProposalJob.perform_now(proposal.id)
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
      assert_not ScenarioProposal.exists?(proposal.id)
      assert_equal 0, ScenarioProposalResult.where(corpus: @corpus).count
    end
  ensure
    release << true if release
    worker&.value
  end
end
