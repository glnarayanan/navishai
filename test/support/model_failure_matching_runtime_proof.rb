abort "Use only the disposable navishai_matching_runtime_proof database." unless ENV["DATABASE_URL"].to_s.split("?").first.to_s.end_with?("/navishai_matching_runtime_proof")

require_relative "../test_helper"
require_relative "../test_helpers/model_failure_matching_test_helper"

class ModelFailureMatchingRuntimeProof < ActiveSupport::TestCase
  include ModelFailureMatchingTestHelper

  test "native runtime grants permit matching and purge without bypassing immutable triggers" do
    connection = ActiveRecord::Base.connection
    connection.execute("SET LOCAL ROLE navishai")
    assert_equal "navishai", connection.select_value("SELECT current_user")
    assert_not connection.select_value("SELECT rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls FROM pg_roles WHERE rolname = current_user")
    build_model_matching_fixture
    with_matching_response do
      request = request_matching
      2.times { ModelFailureMatchingJob.perform_now(request.id) }
      assert_equal "complete", request.reload.state
      result_id = request.model_failure_matching_result.id
      [ ModelFailureMatching, ModelFailureMatchingCandidate, ModelFailureMatchingResult ].each do |model|
        %w[SELECT INSERT UPDATE DELETE].each do |privilege|
          assert connection.select_value("SELECT has_table_privilege(current_user, '#{model.table_name}', '#{privilege}')")
        end
        assert_raises(ActiveRecord::StatementInvalid) do
          model.transaction(requires_new: true) { connection.execute("ALTER TABLE #{model.table_name} DISABLE TRIGGER ALL") }
        end
      end
      assert_raises(ActiveRecord::StatementInvalid) do
        ModelFailureMatching.transaction(requires_new: true) { ModelFailureMatching.where(id: request.id).update_all(input: {}) }
      end
      assert_raises(ActiveRecord::StatementInvalid) do
        ModelFailureMatchingResult.transaction(requires_new: true) { ModelFailureMatchingResult.where(id: result_id).update_all(result: {}) }
      end
      SourcePurge.call(source: @document.source_snapshot.source, membership: @membership)
      assert_not ModelFailureMatching.exists?(request.id)
      assert_not ModelFailureMatchingResult.exists?(result_id)
      assert_empty ModelFailureMatchingCandidate.where(corpus: @corpus)
    end
  end
end
