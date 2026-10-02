require "test_helper"
require_relative "../test_helpers/recorded_evaluation_test_helper"
require_relative "../test_helpers/judge_test_helper"

class RecordedTargetTest < ActiveSupport::TestCase
  include RecordedEvaluationTestHelper
  include JudgeTestHelper

  setup { build_recorded_evaluation }

  test "reported production failure becomes a reviewed regression then the same case passes a later target" do
    run = request_run
    EvaluationRunJob.perform_now(run.id)
    EvaluationRunJob.perform_now(run.id)
    assert_equal "complete", run.reload.state
    result = run.evaluation_results.sole
    assert_equal "fail", result.status
    assert_equal [ "fail", "fail" ], result.decisions.map { |decision| decision["decision"] }
    assert_equal "I changed the SSO configuration for [email redacted]. Try again.", result.output["messages"].sole["content"]
    assert_equal "recorded", result.execution["adapter"]
    assert_equal "recorded-support-v1", result.execution["processing_version"]
    assert_equal @trace_item, run.evaluation_target_version.trace_item
    assert_equal({ "situation" => "SSO stopped after a customer changed the certificate.", "known_facts" => { "plan" => "enterprise", "idp" => "Okta" }, "knowledge" => [] }, run.evaluation_run_items.sole.target_input)
    regression = @corpus.eval_suites.create!(workspace: @workspace, name: "Production failures", kind: "regression")
    admission = result.add_regression!(membership: @membership, suite_id: regression.id, rationale: "Request certificate evidence before recommending changes.")
    assert_equal result, admission.evaluation_result
    assert_equal @membership.user, admission.reviewed_by
    assert_equal @case, admission.eval_case
    corrected = EvaluationTarget.define!(corpus: @corpus, membership: @membership, name: "Corrected fixture agent", configuration: script_configuration(output: support_output(tools: [ "collect_expiry" ])))
    replay = request_run(suite: regression, version: corrected.current_version)
    EvaluationRunJob.perform_now(replay.id)
    assert_equal "pass", replay.evaluation_results.sole.status
    assert_equal @case.id, replay.evaluation_results.sole.eval_case_id
    assert_equal "fail", result.reload.status
  end

  test "replay checks all visible input and never compares hidden expectations or JSON key order" do
    input = @case.scenario_version.target_input
    assert_equal [], input["knowledge"]
    reordered = input.to_a.reverse.to_h.merge("known_facts" => input["known_facts"].to_a.reverse.to_h)
    assert_equal @trace_item.context["support_trace"]["output"], @target.current_version.call(input: reordered, request_key: SecureRandom.uuid)
    [ input.merge("situation" => "SSO failed before any change."), input.merge("known_facts" => { "plan" => "pro", "idp" => "Okta" }),
      input.merge("knowledge" => [ { "reference" => "different-policy", "content" => @knowledge.content } ]),
      input.merge("hidden_facts" => {}) ].each do |different|
      assert_raises(RecordedTarget::Error) { @target.current_version.call(input: different, request_key: SecureRandom.uuid) }
    end
    output = @target.current_version.call(input:, request_key: SecureRandom.uuid)
    output["messages"].sole["content"] = "Changed in memory"
    assert_equal "I changed the SSO configuration for [email redacted]. Try again.", @target.current_version.call(input:, request_key: SecureRandom.uuid)["messages"].sole["content"]
  end

  test "false zero missing fields and exact knowledge references cannot silently change replay context" do
    @trace["input"]["known_facts"].merge!("admin" => false, "retry_count" => 0)
    @trace["input"]["knowledge"] = [ { "reference" => "recorded-policy-4", "content" => "Request diagnostic logs before a configuration change." } ]
    item = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Precise context", kind: "traces", bytes: [ @trace ].to_json).corpus_items.sole
    input = @trace["input"]
    assert_equal [], RecordedTarget.call(trace_item: item, input:)["tool_calls"]
    changed = [ input.merge("known_facts" => input["known_facts"].except("admin")),
      input.merge("known_facts" => input["known_facts"].merge("admin" => nil)),
      input.merge("known_facts" => input["known_facts"].merge("retry_count" => false)),
      input.merge("knowledge" => [ input["knowledge"].sole.merge("reference" => "recorded-policy-5") ]),
      input.merge("knowledge" => [ input["knowledge"].sole.merge("content" => "Change configuration first.") ]) ]
    changed.each { |different| assert_raises(RecordedTarget::Error) { RecordedTarget.call(trace_item: item, input: different) } }
  end

  test "changed context refuses to queue and changed trace versions cannot rewrite old runs" do
    run = request_run
    old_version = @target.current_version
    @trace["output"] = support_output(tools: [ "collect_expiry" ])
    @trace["observed_failure"] = "Still reported bad by an unreviewed importer."
    newer = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Recorded failure fixture", kind: "traces", bytes: [ @trace ].to_json).corpus_items.sole
    @target.revise!(membership: @membership, version_id: old_version.id, configuration: {}, trace_item_id: newer.id)
    assert_equal old_version.id, run.evaluation_target_version_id
    EvaluationRunJob.perform_now(run.id)
    assert_equal "fail", run.evaluation_results.sole.status
    fresh = request_run
    EvaluationRunJob.perform_now(fresh.id)
    assert_equal "pass", fresh.evaluation_results.sole.status
    assert_no_difference "EvaluationTargetVersion.count" do
      @target.revise!(membership: @membership, version_id: @target.current_version_id, configuration: {}, trace_item_id: newer.id)
    end
    @scenario.revise!(membership: @membership, base_version_id: @scenario.current_version_id, attributes: { known_facts: { plan: "pro", idp: "Okta" } })
    @scenario.review!(membership: @membership, version_id: @scenario.current_version_id, decision: "approve")
    @checks = @checks.map { |check| check.merge("scenario_evidence_id" => @scenario.current_version.scenario_evidence.find_by!(corpus_item: @knowledge).id) }
    changed = compile_case
    @suite.eval_suite_cases.delete_all(:delete_all)
    @suite.add_case!(membership: @membership, case_id: changed.id)
    assert_no_difference [ "EvaluationRun.count", "EvaluationRunItem.count" ] do
      assert_raises(RecordedTarget::Error) { request_run }
    end
  end

  test "local replay cannot bypass separate configured judge consent or a stale case list" do
    with_endpoint_approval do
      @outcome_grader.revise!(membership: @membership, version_id: @outcome_grader.current_version_id, kind: "rubric_judge",
        definition: { "rubric" => "Check whether the output claims an unconfirmed change.", "confidence_threshold" => 0.8, "execution" => judge_execution })
      @checks.each { |check| check["grader_version_id"] = @outcome_grader.current_version_id if check["requirement_kind"] == "outcomes" }
      @case = compile_case
      @suite.eval_suite_cases.delete_all(:delete_all)
      @suite.add_case!(membership: @membership, case_id: @case.id)
      assert_no_difference "EvaluationRun.count" do
        assert_raises(EvalCase::Invalid) { request_run }
        assert_raises(EvalCase::Invalid) { request_run(judge_disclose: true, suite_digest: "stale") }
      end
      run = request_run(judge_disclose: true)
      assert run.judge_disclosure
      assert_equal "recorded", run.evaluation_target_version.adapter
    end
  end

  test "foreign wrong source missing trace and SQL rebind fail and source deletion clears copies" do
    foreign_corpus = workspaces(:beta_support).corpora.create!(name: "Foreign")
    foreign = CorpusIntake.call(corpus: foreign_corpus, membership: memberships(:outsider_beta), name: "Trace", kind: "traces", bytes: [ @trace ].to_json).corpus_items.sole
    [ foreign.id, @knowledge.id, nil ].each do |id|
      assert_no_difference "EvaluationTarget.count" do
        assert_raises(RecordedTarget::Error) { EvaluationTarget.define!(corpus: @corpus, membership: @membership, name: "Rejected", adapter: "recorded", configuration: {}, trace_item_id: id) }
      end
    end
    assert_raises(ActiveRecord::InvalidForeignKey) do
      EvaluationTargetVersion.transaction(requires_new: true) do
        version = @target.evaluation_target_versions.build(workspace: @workspace, corpus: @corpus, created_by: @membership.user, number: 2, adapter: "recorded", processing_version: RecordedTarget::VERSION, configuration: {}, trace_item_id: foreign.id)
        version.save!(validate: false)
      end
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      EvaluationTargetVersion.transaction(requires_new: true) { EvaluationTargetVersion.where(id: @target.current_version_id).update_all(trace_item_id: foreign.id) }
    end
    run = request_run
    @snapshot.source.update!(expires_at: 1.minute.ago)
    EvaluationRunJob.perform_now(run.id)
    assert_equal "interrupted", run.reload.state
    assert_empty run.evaluation_results
    assert_raises(RecordedTarget::Error) { @target.current_version.call(input: @trace["input"], request_key: SecureRandom.uuid) }
    SourcePurge.call(source: @snapshot.source, membership: @membership)
    assert_not EvaluationTarget.exists?(corpus: @corpus)
    assert_not EvaluationRun.exists?(corpus: @corpus)
    assert_not Scenario.exists?(corpus: @corpus)
    assert_not EvalCase.exists?(corpus: @corpus)
  end
end
