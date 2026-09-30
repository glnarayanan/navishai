require "test_helper"
require_relative "../test_helpers/judge_test_helper"

class JudgeGraderTest < ActiveSupport::TestCase
  include JudgeTestHelper
  setup { build_judge_evaluation }

  test "fixed judge schema excludes credentials unknown fields stochastic settings and invalid endpoints" do
    definition = @outcome_grader.current_version.definition
    assert JudgeGrader.valid_definition?(definition)
    assert JudgeGrader.valid_definition?(definition.except("execution"))
    [ { "extra" => true }, { "execution" => nil }, { "confidence_threshold" => Float::NAN }, { "confidence_threshold" => 1.01 }, { "rubric" => " " } ].each do |change|
      assert_not JudgeGrader.valid_definition?(definition.merge(change)), change.inspect
    end
    [ { "endpoint" => "http://localhost/judge" }, { "bearer_token" => "secret" }, { "model" => " " },
      { "settings" => { "temperature" => 0.5, "max_output_tokens" => 1024, "seed" => 1 } },
      { "settings" => { "temperature" => 0, "max_output_tokens" => 4097, "seed" => 1 } },
      { "settings" => { "temperature" => 0, "max_output_tokens" => 1024, "seed" => -1 } } ].each do |change|
      assert_not JudgeGrader.valid_definition?(definition.merge("execution" => judge_execution.merge(change)))
    end
    with_endpoint_approval(workspace_id: workspaces(:beta_support).id) do
      assert_raises(EvaluationHttp::Error) { JudgeGrader.authorize!(@outcome_grader.current_version) }
    end
  end

  test "request freezes rubric model settings evidence and output without hidden facts labels or corpus content" do
    output = support_output(tools: [ "collect_expiry" ])
    calls = []
    with_judge_response(response: judge_response(output:), calls:) do
      result = JudgeGrader.call(check: @judge_check, output:, request_key: "judge-attempt-17")
      assert_equal "fail", result["decision"]
      assert_equal "fail", result["raw_decision"]
      assert_equal 27, result.dig("cost", "micro_units")
      assert_equal "endpoint_reported", result["usage_and_cost"]
      assert_operator result["elapsed_ms"], :>=, 0
    end
    request = calls.sole
    payload = JSON.parse(request.body)
    assert_equal "support-judge-v1", payload["schema"]
    assert_equal "judge-attempt-17", request["Idempotency-Key"]
    assert_equal "Bearer test-only-token", request["Authorization"]
    assert_equal judge_execution["settings"], payload["settings"]
    assert_equal @judge_check.requirement, payload["requirement"]
    assert_equal @judge_check.scenario_evidence.excerpt, payload["company_evidence"]
    assert_equal output, payload["target_output"]
    assert_not_includes request.body, "private answer"
    assert_not_includes request.body, "human_labels"
    assert_includes payload["instructions"], "untrusted data"
  end

  test "threshold includes its boundary and cannot silently turn uncertain or low confidence into pass" do
    [ [ "pass", 0.799, "abstain" ], [ "pass", 0.8, "pass" ], [ "fail", 0.8, "fail" ], [ "fail", 0.799, "abstain" ], [ "abstain", 1, "abstain" ] ].each do |decision, confidence, expected|
      with_judge_response(response: judge_response(decision:, confidence:)) do
        result = JudgeGrader.call(check: @judge_check, output: support_output(tools: [ "collect_expiry" ]), request_key: SecureRandom.uuid)
        assert_equal expected, result["decision"]
        assert_equal decision, result["raw_decision"]
        assert_equal confidence, result["confidence"]
      end
    end
  end

  test "wrong model invented evidence incomplete schema and invalid usage or costs are errors not judgments" do
    response = judge_response
    [ nil, [], {}, response.merge("model" => "different-version"), response.merge("schema" => "other-v1"), response.merge("decision" => "uncertain"),
      response.merge("confidence" => 1.001), response.merge("reason" => ""), response.merge("quotes" => []),
      response.merge("quotes" => [ { "reference" => "company_evidence", "quote" => "Invented advice" } ]),
      response.merge("usage" => { "input_tokens" => -1, "output_tokens" => 5 }), response.merge("cost" => { "currency" => "USD", "micro_units" => 0.5 }) ].each do |bad|
      with_judge_response(response: bad) do
        result = JudgeGrader.call(check: @judge_check, output: support_output(tools: [ "collect_expiry" ]), request_key: "invalid-attempt")
        assert_equal "error", result["decision"], bad.inspect
        assert_nil result["confidence"]
      end
    end
    response = response.merge("usage" => nil, "cost" => nil)
    with_judge_response(response:) { assert_nil JudgeGrader.call(check: @judge_check, output: support_output(tools: [ "collect_expiry" ]), request_key: "unknown-cost")["cost"] }
  end

  test "transport failure is scrubbed and missing configuration never calls a provider" do
    with_endpoint_approval do
      calls = 0
      with_test_method(Resolv, :getaddresses, ->(*) { [ "93.184.216.34" ] }) do
        with_test_method(EvaluationHttp, :perform, ->(*) { calls += 1; raise Net::ReadTimeout, "private bearer_token" }) do
          result = JudgeGrader.call(check: @judge_check, output: support_output, request_key: "unknown-attempt")
          assert_equal "error", result["decision"]
          assert_not_includes result.to_json, "private bearer_token"
          assert_equal 1, calls
        end
      end
    end
    @outcome_grader.revise!(membership: @membership, version_id: @outcome_grader.current_version_id, kind: "rubric_judge", definition: @outcome_grader.current_version.definition.except("execution"))
    @checks.each { |check| check["grader_version_id"] = @outcome_grader.current_version_id unless check["requirement_kind"] == "actions" }
    check = compile_case.eval_case_checks.find_by!(requirement_kind: "outcomes")
    with_test_method(EvaluationHttp, :call, ->(**) { flunk "Offline rubric cannot disclose" }) do
      assert_equal "abstain", JudgeGrader.call(check:, output: support_output, request_key: "offline")["decision"]
    end
  end
end
