require "test_helper"
require_relative "../test_helpers/evaluation_test_helper"
require_relative "../test_helpers/http_target_test_helper"

class HttpEvaluationTest < ActiveSupport::TestCase
  include EvaluationTestHelper
  include HttpTargetTestHelper
  setup { build_evaluation }

  test "HTTP definition request and dispatch require separate approvals and expose only fixed visible input" do
    with_endpoint_approval do
      target = define_http_target
      assert_equal "http", target.current_version.adapter
      assert_equal HttpTarget::VERSION, target.current_version.processing_version
      assert_equal({ "endpoint" => HTTP_ENDPOINT }, target.current_version.configuration)
      assert_equal @membership.user, target.current_version.created_by
      assert_no_difference "EvaluationRun.count" do
        assert_raises(EvalCase::Invalid) { request_run(version: target.current_version) }
        assert_raises(EvalCase::Invalid) { EvaluationRun.request!(suite: @suite, membership: @membership, target_version_id: target.current_version_id, disclose: "true") }
      end
      run = EvaluationRun.request!(suite: @suite, membership: @membership, target_version_id: target.current_version_id, disclose: true)
      item = run.evaluation_run_items.sole
      sent = []
      with_test_method(HttpTarget, :call, ->(**args) { sent << args; support_output }) do
        EvaluationRunJob.perform_now(run.id)
        EvaluationRunJob.perform_now(run.id)
      end
      assert_equal 1, sent.size
      assert_equal @workspace.id, sent.sole.fetch(:workspace_id)
      assert_equal item.request_key, sent.sole.fetch(:request_key)
      assert_match(/\A[0-9a-f-]{36}\z/, item.request_key)
      assert_equal %w[knowledge known_facts situation], sent.sole.fetch(:input).keys.sort
      assert_not_includes sent.sole.fetch(:input).to_json, "private answer"
      assert_not_includes sent.sole.fetch(:input).to_json, "Identify certificate expiry as a possible cause."
      result = run.evaluation_results.sole
      assert_equal "fail", result.status
      assert_equal "http", result.execution.fetch("adapter")
      assert_equal HttpTarget::VERSION, result.execution.fetch("processing_version")
      assert_operator result.execution.fetch("elapsed_ms"), :>=, 0
      assert_nil result.execution.fetch("cost")
      assert_raises(ActiveRecord::StatementInvalid) { EvaluationResult.transaction(requires_new: true) { EvaluationResult.where(id: result.id).update_all(execution: {}) } }
      assert_raises(ActiveRecord::StatementInvalid) { EvaluationRunItem.transaction(requires_new: true) { EvaluationRunItem.where(id: item.id).update_all(request_key: SecureRandom.uuid) } }
    end
  end

  test "operator revocation before dispatch returns an error without disclosure and timeout does not retry" do
    with_endpoint_approval do
      target = define_http_target
      run = EvaluationRun.request!(suite: @suite, membership: @membership, target_version_id: target.current_version_id, disclose: true)
      ENV["NAVISHAI_EVALUATION_ENDPOINTS"] = "[]"
      with_test_method(HttpTarget, :perform, ->(*) { flunk "Revoked endpoint cannot connect" }) { EvaluationRunJob.perform_now(run.id) }
      result = run.evaluation_results.sole
      assert_equal "error", result.status
      assert_includes result.error, "not approved"
      assert_empty result.decisions
      assert_nil result.output
      assert_no_difference "EvaluationRun.count" do
        assert_raises(HttpTarget::Error) { EvaluationRun.request!(suite: @suite, membership: @membership, target_version_id: target.current_version_id, disclose: true) }
      end
    end
    with_endpoint_approval do
      target = define_http_target
      run = EvaluationRun.request!(suite: @suite, membership: @membership, target_version_id: target.current_version_id, disclose: true)
      calls = 0
      with_test_method(Resolv, :getaddresses, ->(*) { [ "93.184.216.34" ] }) do
        with_test_method(HttpTarget, :perform, ->(*) { calls += 1; raise Net::ReadTimeout, "private-token-response" }) do
          2.times { EvaluationRunJob.perform_now(run.id) }
        end
      end
      assert_equal 1, calls
      result = run.evaluation_results.sole
      assert_equal "error", result.status
      assert_includes result.error, "remote outcome may be unknown"
      assert_not_includes result.error, "private-token-response"
      regression = @corpus.eval_suites.create!(workspace: @workspace, name: "Regressions", kind: "regression")
      assert_raises(EvalCase::Invalid) { result.add_regression!(membership: @membership, suite_id: regression.id, rationale: "Not behavioural evidence") }
    end
  end

  test "revoked scenario during target call prevents retaining output or repeating execution" do
    with_endpoint_approval do
      target = define_http_target
      run = EvaluationRun.request!(suite: @suite, membership: @membership, target_version_id: target.current_version_id, disclose: true)
      with_test_method(HttpTarget, :call, ->(**) { @scenario.review!(membership: @membership, version_id: @scenario.current_version_id, decision: "reject"); support_output }) do
        EvaluationRunJob.perform_now(run.id)
      end
      assert_equal "interrupted", run.reload.state
      assert_empty run.evaluation_results
      with_test_method(HttpTarget, :call, ->(**) { flunk "An interrupted run must not retry" }) { EvaluationRunJob.perform_now(run.id) }
    end
  end
end
