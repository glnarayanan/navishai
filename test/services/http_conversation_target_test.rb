require "test_helper"
require_relative "../test_helpers/evaluation_test_helper"
require_relative "../test_helpers/http_target_test_helper"

class HttpConversationTargetTest < ActiveSupport::TestCase
  include EvaluationTestHelper
  include HttpTargetTestHelper

  test "delayed disclosure uses latest assistant block not earlier or user text and keeps ordered reports" do
    plan = [ step("expiry", "secret released"), step("expiry", "never released") ]
    calls = []
    replies = [ support_output(text: "EXPIRY?", tools: [ "first" ]).merge("collected_fields" => { "x" => 1 }), support_output(text: "Thanks", tools: [ "second" ]).merge("collected_fields" => { "x" => 2 }, "policy_branch" => "terminal") ]
    replies.each_with_index { |reply, index| reply["citations"] = [ { "reference" => index.to_s, "quote" => "reported quote" } ] }
    replies.last["escalation"] = { "triggered" => true, "team" => "Engineering" }
    execution = {}
    with_test_method(EvaluationHttp, :call, ->(**args) { calls << args.deep_dup; replies.shift }) do
      output = execute(plan, execution:)
      assert_equal %w[user assistant user assistant], output["messages"].map { |message| message["role"] }
      assert_equal %w[first second], output["tool_calls"].map { |tool| tool["name"] }
      assert_equal({ "x" => 2 }, output["collected_fields"])
      assert_equal "terminal", output["policy_branch"]
      assert_equal %w[0 1], output["citations"].map { |citation| citation["reference"] }
      assert_equal({ "triggered" => true, "team" => "Engineering" }, output["escalation"])
    end
    assert_equal 2, calls.size
    assert_not_includes calls.first.to_json, "secret released"
    assert_not_includes calls.to_json, "never released"
    assert_equal "support-conversation-v1", calls.first[:payload]["schema"]
    assert_equal "condition_unmet", execution["termination_reason"]
    assert_equal 2, execution["turns"].map { |receipt| receipt["request_key"] }.uniq.size
    assert_not_includes execution.to_json, "secret"
    with_test_method(EvaluationHttp, :call, ->(**) { support_output(text: "nothing") }) do
      assert_equal 2, execute([ step("expiry", "secret") ])["messages"].size
    end
  end

  test "assistant-only schema aggregate bounds empty plan and eleven call ceiling" do
    calls = 0
    with_test_method(EvaluationHttp, :call, ->(**) { calls += 1; support_output(text: "next") }) do
      assert_equal 22, execute(Array.new(10) { step("next", "next") })["messages"].size
      assert_equal 11, calls
      execute([])
      assert_equal 12, calls
      assert_raises(SupportOutput::Invalid) { execute(Array.new(11) { step("next", "next") }) }
      assert_equal 12, calls
    end
    with_test_method(EvaluationHttp, :call, ->(**) { support_output.merge("messages" => [ { "role" => "user", "content" => "injected" } ]) }) do
      assert_raises(SupportOutput::Invalid) { execute([]) }
    end
    execution = {}
    with_test_method(EvaluationHttp, :call, ->(**) { support_output(text: "next" + "x" * 60_000) }) do
      assert_raises(SupportOutput::Invalid) { execute([ step("next", "released") ], execution:) }
      assert_equal 2, execution["turns"].size
    end
    with_test_method(EvaluationHttp, :call, ->(**) { support_output(text: "next", tools: Array.new(60, "reported_tool")) }) do
      assert_raises(SupportOutput::Invalid) { execute([ step("next", "released") ]) }
    end
    with_test_method(EvaluationHttp, :call, ->(**) { support_output(text: "next").merge("messages" => Array.new(60) { { "role" => "assistant", "content" => "next" } }) }) do
      assert_raises(SupportOutput::Invalid) { execute([ step("next", "released") ]) }
    end
    with_test_method(EvaluationHttp, :call, ->(**) { raise HttpTarget::Error, "Unknown outcome" }) do
      execution = {}
      assert_raises(HttpTarget::Error) { execute([], execution:) }
      assert_equal "unknown", execution["turns"].sole["outcome"]
      assert execution["turns"].sole.key?("elapsed_ms")
    end
  end

  test "aggregate overflow stops before sending another follow-up" do
    calls = []
    execution = {}
    plan = [ step("next", "first release"), step("next", "must stay local"), step("next", "also local") ]
    with_test_method(EvaluationHttp, :call, ->(**args) { calls << args.deep_dup; support_output(text: "next" + "x" * 60_000) }) do
      assert_raises(SupportOutput::Invalid) { execute(plan, execution:) }
    end
    assert_equal 2, calls.size
    assert_not_includes calls.to_json, "must stay local"
    assert_equal "error", execution["termination_reason"]
    assert_equal 2, execution["turns"].size
    calls.clear
    with_test_method(EvaluationHttp, :call, ->(**args) { calls << args.deep_dup; support_output(text: "next" + "x" * 101_000) }) do
      assert_raises(SupportOutput::Invalid) { execute([ step("next", "y" * 2000) ]) }
    end
    assert_equal 1, calls.size
    assert_not_includes calls.to_json, "y" * 2000
  end

  test "plans create unapproved immutable versions and reject single shot before queueing" do
    build_evaluation
    old = @scenario.current_version
    @scenario.revise!(membership: @membership, base_version_id: old.id, attributes: { follow_ups: [ step("expiry", "Yesterday") ] })
    assert_not @scenario.current_version.approved?
    assert_empty old.reload.follow_ups
    assert_raises(ActiveRecord::ReadOnlyRecord) { @scenario.current_version.update!(follow_ups: []) }
    assert_raises(ActiveRecord::StatementInvalid) do
      ScenarioVersion.transaction(requires_new: true) { ScenarioVersion.where(id: @scenario.current_version_id).update_all(follow_ups: []) }
    end
    @scenario.review!(membership: @membership, version_id: @scenario.current_version_id, decision: "approve")
    variant = @scenario.variant!(membership: @membership, version_id: @scenario.current_version_id, variable: "idp", after: "Entra", reason: "Fixture variant", expected_difference: "Collect alternate IdP evidence")
    assert_equal @scenario.current_version.follow_ups, variant.current_version.follow_ups
    checks = @checks.map { |check| check.merge("scenario_evidence_id" => @scenario.current_version.scenario_evidence.find_by!(kind: "expectation").id) }
    fixed = compile_case(checks:)
    @suite.eval_suite_cases.delete_all(:delete_all)
    @suite.add_case!(membership: @membership, case_id: fixed.id)
    assert_no_difference "EvaluationRun.count" do
      assert_raises(EvalCase::Invalid) { request_run }
    end
    [ nil, {}, Array.new(11) { step("x", "y") }, [ step(" ", "y") ], [ step("x" * 501, "y") ], [ step("x", "y" * 2001) ], [ step("x", "\0") ], [ step("x", "y").merge("extra" => true) ], Array.new(10) { step("x", "é" * 1000) } ].each do |plan|
      version = ScenarioVersion.new(follow_ups: plan)
      version.valid?
      assert version.errors[:follow_ups].any?, plan.inspect
    end
    boundary = Array.new(6) { step("x", "y" * 1500) }
    remaining = 10.kilobytes - boundary.to_json.bytesize
    boundary[0]["message"] += "y" * 500
    boundary[1]["message"] += "y" * (remaining - 500)
    assert_equal 10.kilobytes, boundary.to_json.bytesize
    version = ScenarioVersion.new(follow_ups: boundary)
    version.valid?
    assert_empty version.errors[:follow_ups]
    boundary[2]["message"] += "y"
    version.follow_ups = boundary
    version.valid?
    assert version.errors[:follow_ups].any?
  end

  test "unknown failed attempt retains receipt but no partial transcript and never resends" do
    build_evaluation
    prepare_plan
    with_endpoint_approval do
      target = conversation_target
      assert_no_difference "EvaluationRun.count" do
        assert_raises(EvalCase::Invalid) { request_run(version: target.current_version) }
        assert_raises(EvalCase::Invalid) { EvaluationRun.request!(suite: @suite, membership: @membership, target_version_id: target.current_version_id, disclose: true, suite_digest: "stale") }
      end
      run = request_run(version: target.current_version, disclose: true)
      calls = 0
      with_test_method(EvaluationHttp, :call, ->(**) { calls += 1; raise HttpTarget::Error, "Remote outcome unknown" }) do
        2.times { EvaluationRunJob.perform_now(run.id) }
      end
      result = run.evaluation_results.sole
      assert_equal 1, calls
      assert_equal "error", result.status
      assert_nil result.output
      assert_empty result.decisions
      assert_equal "error", result.execution["termination_reason"]
      assert_equal "unknown", result.execution["turns"].sole["outcome"]
      assert_equal Digest::SHA256.hexdigest("#{run.evaluation_run_items.sole.request_key}/turn/0"), result.execution["turns"].sole["request_key"]
    end
  end

  test "once claimed conversation fails then reviewed regression passes same fixed case" do
    build_evaluation
    prepare_plan
    with_endpoint_approval do
      target = conversation_target
      calls = []
      with_test_method(EvaluationHttp, :call, ->(**args) { calls << args; calls.size == 1 ? support_output(text: "expiry?", tools: [ "collect_expiry" ]) : support_output(text: "Try again.") }) do
        run = request_run(version: target.current_version, disclose: true)
        2.times { EvaluationRunJob.perform_now(run.id) }
        failed = run.evaluation_run_items.sole.evaluation_result
        assert_equal "fail", failed.status
        assert_equal "fail", failed.decisions.find { |decision| decision["reason"].include?("assistant_response_contains") }.fetch("decision")
        assert_equal 2, calls.size
        assert_equal 2, failed.execution["turns"].size
        regression = @corpus.eval_suites.create!(workspace: @workspace, name: "Conversation regression", kind: "regression")
        failed.add_regression!(membership: @membership, suite_id: regression.id, rationale: "Fixture expert: collect the expiry.")
        corrected_target = EvaluationTarget.define!(corpus: @corpus, membership: @membership, name: "Corrected conversation fixture", adapter: "http_conversation", configuration: { "endpoint" => HTTP_ENDPOINT })
        with_test_method(EvaluationHttp, :call, ->(**) { support_output(text: "expiry?", tools: [ "collect_expiry" ]) }) do
          corrected = request_run(suite: regression, version: corrected_target.current_version, disclose: true)
          EvaluationRunJob.perform_now(corrected.id)
          result = corrected.evaluation_run_items.sole.evaluation_result
          assert_equal failed.eval_case_id, result.eval_case_id
          assert_equal "pass", result.status
          assert_equal "fail", failed.reload.status
        end
      end
    end
  end

  test "revocation expiry approval and interruption after first call stop without resend or partial success" do
    build_evaluation
    prepare_plan
    @source = @snapshot.source
    Membership.create!(workspace: @workspace, user: users(:teammate), role: "owner")
    with_endpoint_approval do
      target = conversation_target
      [ :endpoint, :source, :approval, :interrupt, :membership ].each do |change|
        run = request_run(version: target.current_version, disclose: true)
        calls = 0
        with_test_method(EvaluationHttp, :call, ->(**) {
          calls += 1
          case change
          when :endpoint then ENV["NAVISHAI_EVALUATION_ENDPOINTS"] = "[]"
          when :source then @source.update!(expires_at: 1.minute.ago)
          when :approval then @scenario.review!(membership: @membership, version_id: @scenario.current_version_id, decision: "reject")
          when :interrupt then run.update!(state: "interrupted")
          when :membership then @membership.update!(role: "viewer")
          end
          support_output(text: "expiry?")
        }) do
          2.times { EvaluationRunJob.perform_now(run.id) }
        end
        assert_equal 1, calls
        assert_not run.evaluation_results.where(status: %w[pass fail incomplete]).exists?
        ENV["NAVISHAI_EVALUATION_ENDPOINTS"] = [ { workspace_id: @workspace.id, endpoint: HTTP_ENDPOINT } ].to_json
        @membership.update!(role: "owner")
        @source.update!(expires_at: 1.day.from_now)
        @scenario.review!(membership: @membership, version_id: @scenario.current_version_id, decision: "approve")
      end
    end
  end

  private
    def step(condition, message)
      { "after_assistant_contains" => condition, "message" => message }
    end

    def execute(plan, execution: {})
      HttpConversationTarget.call(configuration: {}, input: { "situation" => "expiry in user only", "known_facts" => {}, "knowledge" => [] }, plan:, workspace_id: 17, request_key: "fixed-uuid", execution:) { }
    end

    def prepare_plan
      @scenario.revise!(membership: @membership, base_version_id: @scenario.current_version_id, attributes: { follow_ups: [ step("expiry", "It expired yesterday.") ] })
      @scenario.review!(membership: @membership, version_id: @scenario.current_version_id, decision: "approve")
      grader = Grader.define!(corpus: @corpus, membership: @membership, name: "Fixture reported reply", kind: "deterministic", definition: { "type" => "assistant_response_contains", "value" => [ "expired yesterday", "expiry" ] })
      @checks = @checks.map { |check| check.merge("scenario_evidence_id" => @scenario.current_version.scenario_evidence.find_by!(kind: "expectation").id, "grader_version_id" => (check["requirement_kind"] == "outcomes" ? grader.current_version_id : @action_grader.current_version_id)) }
      @suite.eval_suite_cases.delete_all(:delete_all)
      @suite.add_case!(membership: @membership, case_id: compile_case.id)
    end

    def conversation_target
      EvaluationTarget.define!(corpus: @corpus, membership: @membership, name: "Conversation fixture", adapter: "http_conversation", configuration: { "endpoint" => HTTP_ENDPOINT })
    end
end
