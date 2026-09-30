require "test_helper"
require_relative "../test_helpers/evaluation_test_helper"

class EvaluationTest < ActiveSupport::TestCase
  include EvaluationTestHelper
  setup { build_evaluation }

  test "run freezes suite membership visible input and target version before target edits" do
    original = @target.current_version
    run = request_run
    input = run.evaluation_run_items.sole.target_input
    assert_equal %w[knowledge known_facts situation], input.keys.sort
    assert_not_includes input.to_json, "private answer"
    assert_not_includes input.to_json, "Identify certificate expiry as a possible cause."
    assert_equal ScriptedTarget::VERSION, original.processing_version
    @target.revise!(membership: @membership, version_id: original.id, configuration: script_configuration(output: support_output(tools: [ "collect_expiry" ])))
    @suite.eval_suite_cases.delete_all(:delete_all)
    assert_equal original, run.reload.evaluation_target_version
    EvaluationRunJob.perform_now(run.id)
    assert_equal "complete", run.reload.state
    assert_equal [ @case.id ], run.evaluation_run_items.pluck(:eval_case_id)
    result = run.evaluation_results.sole
    assert_equal "fail", result.status
    assert_equal({ @action_grader.current_version_id => "fail", @outcome_grader.current_version_id => "abstain" }, result.decisions.to_h { |decision| decision.values_at("grader_version_id", "decision") })
    assert_equal "I have reset your SSO configuration. Try again.", result.output.fetch("messages").sole.fetch("content")
    assert_no_difference "EvaluationResult.count" do
      with_scripted_call(->(**) { flunk "Duplicate delivery must not execute a target" }) { EvaluationRunJob.perform_now(run.id) }
    end
    assert_raises(EvalCase::Invalid) { @target.revise!(membership: @membership, version_id: original.id, configuration: original.configuration) }
    assert_no_difference "EvaluationTargetVersion.count" do
      @target.revise!(membership: @membership, version_id: @target.current_version_id, configuration: @target.current_version.configuration)
    end
  end

  test "passing deterministic actions with an unexecuted judge cannot yield a case pass" do
    @target.revise!(membership: @membership, version_id: @target.current_version_id, configuration: script_configuration(output: support_output(tools: [ "collect_expiry" ])))
    run = request_run
    EvaluationRunJob.perform_now(run.id)
    assert_equal "incomplete", run.evaluation_results.sole.status
    assert_equal({ @action_grader.current_version_id => "pass", @outcome_grader.current_version_id => "abstain" }, run.evaluation_results.sole.decisions.to_h { |decision| decision.values_at("grader_version_id", "decision") })
    assert_raises(EvalCase::Invalid) { run.evaluation_results.sole.add_regression!(membership: @membership, suite_id: @suite.id, rationale: "Not a failure") }
  end

  test "malformed output is an execution error not a behavioural failure and never enters regressions" do
    run = request_run
    with_scripted_call(->(**) { {} }) { EvaluationRunJob.perform_now(run.id) }
    result = run.evaluation_results.sole
    assert_equal "complete", run.reload.state
    assert_equal "error", result.status
    assert_nil result.output
    assert_empty result.decisions
    regression = @corpus.eval_suites.create!(workspace: @workspace, name: "Regressions", kind: "regression")
    assert_raises(EvalCase::Invalid) { result.add_regression!(membership: @membership, suite_id: regression.id, rationale: "Bad JSON") }
  end

  test "access revocation and changed evidence stop queued execution without disclosure or retry" do
    Membership.create!(workspace: @workspace, user: users(:teammate), role: :owner)
    [ -> { @membership.update!(role: :viewer) }, -> { @scenario.review!(membership: @membership, version_id: @scenario.current_version_id, decision: "reject") },
      -> { @knowledge.source_snapshot.source.update!(expires_at: 1.second.ago) } ].each do |change|
      run = request_run
      change.call
      with_scripted_call(->(**) { flunk "Revoked or expired run must not execute" }) { EvaluationRunJob.perform_now(run.id) }
      assert_equal "interrupted", run.reload.state
      assert_empty run.evaluation_results
      EvaluationRunJob.perform_now(run.id)
      assert_empty run.evaluation_results
      @membership.update!(role: :owner)
      @knowledge.source_snapshot.source.update!(expires_at: 1.year.from_now)
      @scenario.review!(membership: @membership, version_id: @scenario.current_version_id, decision: "approve")
    end
  end

  test "worker faults keep prior results and an old claimed run needs deliberate human interruption" do
    other_checks = @checks.map { |check| check["requirement_kind"] == "actions" ? check.merge("grader_version_id" => @outcome_grader.current_version_id) : check }
    @suite.add_case!(membership: @membership, case_id: compile_case(checks: other_checks).id)
    run = request_run
    calls = 0
    output = support_output
    with_scripted_call(->(**) { calls += 1; raise IOError, "private worker text" if calls == 2; output }) { EvaluationRunJob.perform_now(run.id) }
    assert_equal "interrupted", run.reload.state
    assert_equal 1, run.evaluation_results.count
    assert_not_includes run.error, "private worker text"
    EvaluationRunJob.perform_now(run.id)
    assert_equal 1, run.evaluation_results.count
    claimed = request_run
    claimed.update!(state: "running", started_at: Time.current)
    EvaluationRunJob.perform_now(claimed.id)
    assert_empty claimed.evaluation_results
    assert_raises(EvalCase::Invalid) { claimed.interrupt!(membership: @membership) }
    travel 11.minutes do
      claimed.interrupt!(membership: @membership)
      assert_equal "interrupted", claimed.reload.state
    end
    queued = request_run
    queued.interrupt!(membership: @membership)
    EvaluationRunJob.perform_now(queued.id)
    assert_empty queued.evaluation_results
  end

  test "reviewed regressions freeze source failure and corrected target passes the same contract" do
    @outcome_grader.revise!(membership: @membership, version_id: @outcome_grader.current_version_id, kind: "deterministic", definition: { "type" => "text_contains", "value" => "certificate expiry" })
    checks = @checks.map { |check| check["requirement_kind"] == "outcomes" ? check.merge("grader_version_id" => @outcome_grader.current_version_id) : check }
    @case = compile_case(checks:)
    @suite.eval_suite_cases.delete_all(:delete_all)
    @suite.add_case!(membership: @membership, case_id: @case.id)
    failed = request_run
    EvaluationRunJob.perform_now(failed.id)
    result = failed.evaluation_results.sole
    regression = @corpus.eval_suites.create!(workspace: @workspace, name: "SSO regressions", kind: "regression")
    assert_raises(ActiveRecord::RecordInvalid) { result.add_regression!(membership: @membership, suite_id: regression.id, rationale: "") }
    assert_empty regression.reload.eval_cases
    assert_raises(EvalCase::Invalid) { result.add_regression!(membership: @membership, suite_id: @suite.id, rationale: "Wrong suite") }
    record = result.add_regression!(membership: @membership, suite_id: regression.id, rationale: "Never claim configuration changes before collecting expiry evidence.")
    assert_equal [ result, @case, @membership.user ], [ record.evaluation_result, record.eval_case, record.reviewed_by ]
    assert_no_difference "RegressionCase.count" do
      assert_equal record, result.add_regression!(membership: @membership, suite_id: regression.id, rationale: "A repeat must not rewrite history")
    end
    @target.revise!(membership: @membership, version_id: @target.current_version_id, configuration: script_configuration(output: support_output(tools: [ "collect_expiry" ])))
    corrected = request_run(suite: regression)
    EvaluationRunJob.perform_now(corrected.id)
    assert_equal "pass", corrected.evaluation_results.sole.status
    assert_equal "fail", result.reload.status
    assert_equal @case.id, corrected.evaluation_results.sole.eval_case_id
  end

  test "immutable definitions results and regression records reject Ruby and SQL updates" do
    run = request_run
    EvaluationRunJob.perform_now(run.id)
    suite = @corpus.eval_suites.create!(workspace: @workspace, name: "Regression", kind: "regression")
    result = run.evaluation_results.sole
    record = result.add_regression!(membership: @membership, suite_id: suite.id, rationale: "Required tool was not called.")
    [ [ EvaluationTargetVersion, @target.current_version, { configuration: script_configuration(output: support_output) } ], [ EvaluationRunItem, run.evaluation_run_items.sole, { target_input: {} } ],
      [ EvaluationResult, result, { status: "pass" } ], [ RegressionCase, record, { rationale: "Rewrite" } ] ].each do |model, object, attributes|
      assert_raises(ActiveRecord::ReadOnlyRecord) { object.update!(attributes) }
      assert_raises(ActiveRecord::StatementInvalid) { model.transaction(requires_new: true) { model.where(id: object.id).update_all(attributes) } }
    end
    assert_raises(ActiveRecord::ReadonlyAttributeError) { run.update!(processing_version: "rewrite") }
    assert_raises(ActiveRecord::StatementInvalid) { EvaluationRun.transaction(requires_new: true) { EvaluationRun.where(id: run.id).update_all(processing_version: "rewrite") } }
    assert_raises(ActiveRecord::RecordNotUnique) { EvaluationResult.transaction(requires_new: true) { EvaluationResult.create!(result.attributes.except("id")) } }
  end

  test "foreign target requests and mismatched run result links fail and purge removes every derived copy" do
    foreign = workspaces(:beta_support).corpora.create!(name: "Other company")
    memberships(:outsider_beta).update!(role: :manager)
    target = EvaluationTarget.define!(corpus: foreign, membership: memberships(:outsider_beta), name: "Other", configuration: script_configuration)
    assert_raises(ActiveRecord::RecordNotFound) { request_run(version: target.current_version) }
    assert_raises(Current::RoleAccessDenied) { EvaluationTarget.define!(corpus: @corpus, membership: memberships(:outsider_beta), name: "Wrong owner", configuration: script_configuration) }
    run = request_run
    assert_raises(ActiveRecord::InvalidForeignKey) { EvaluationRun.transaction(requires_new: true) { EvaluationRun.create!(run.attributes.except("id").merge("evaluation_target_version_id" => target.current_version_id)) } }
    assert_raises(ActiveRecord::InvalidForeignKey) { EvaluationTarget.transaction(requires_new: true) { @target.update!(current_version_id: target.current_version_id) } }
    @target.reload
    EvaluationRunJob.perform_now(run.id)
    result = run.evaluation_results.sole
    other = compile_case(checks: @checks.map { |check| check.merge("grader_version_id" => @action_grader.current_version_id) })
    other_item = run.evaluation_run_items.create!(workspace: @workspace, corpus: @corpus, eval_case: other, target_input: other.scenario_version.target_input)
    assert_raises(ActiveRecord::InvalidForeignKey) { EvaluationResult.transaction(requires_new: true) { EvaluationResult.create!(result.attributes.except("id").merge("evaluation_run_item_id" => other_item.id)) } }
    regression = @corpus.eval_suites.create!(workspace: @workspace, name: "Regression", kind: "regression")
    record = result.add_regression!(membership: @membership, suite_id: regression.id, rationale: "Retain missing diagnostics.")
    assert_raises(ActiveRecord::InvalidForeignKey) { RegressionCase.transaction(requires_new: true) { RegressionCase.create!(record.attributes.except("id").merge("eval_case_id" => other.id, "eval_suite_id" => @suite.id)) } }
    @knowledge.source_snapshot.source.update!(expires_at: 1.second.ago)
    assert_raises(EvalCase::Invalid) { request_run }
    assert_raises(EvalCase::Invalid) { result.add_regression!(membership: @membership, suite_id: regression.id, rationale: "Expired") }
    SourcePurge.call(source: @knowledge.source_snapshot.source, membership: @membership)
    [ EvaluationTarget, EvaluationTargetVersion, EvaluationRun, EvaluationRunItem, EvaluationResult, RegressionCase ].each { |model| assert_empty model.where(corpus: @corpus) }
    assert_empty regression.reload.eval_cases
    assert_equal target, EvaluationTarget.find(target.id)
  end

  test "run request bounds checks independently from case count before creating jobs" do
    empty = @corpus.eval_suites.create!(workspace: @workspace, name: "Empty")
    assert_raises(EvalCase::Invalid) { request_run(suite: empty) }
    requirements = ScenarioVersion::REQUIREMENT_TYPES.to_h { |kind| [ kind, 20.times.map { |index| "#{kind} statement #{index}" } ] }
    @scenario.revise!(membership: @membership, base_version_id: @scenario.current_version_id, attributes: { requirements: })
    @scenario.review!(membership: @membership, version_id: @scenario.current_version_id, decision: "approve")
    checks = requirements.flat_map { |kind, statements| statements.each_index.map { |index| @checks.first.merge("requirement_kind" => kind, "requirement_index" => index, "scenario_evidence_id" => @scenario.current_version.scenario_evidence.first.id) } }
    full = compile_case(checks:)
    @suite.eval_suite_cases.delete_all(:delete_all)
    @suite.add_case!(membership: @membership, case_id: full.id)
    assert_equal 100, request_run.evaluation_run_items.sole.eval_case.eval_case_checks.count
    extra = compile_case(checks: checks.map { |check| check.merge("grader_version_id" => @outcome_grader.current_version_id) })
    @suite.add_case!(membership: @membership, case_id: extra.id)
    assert_no_difference "EvaluationRun.count" do
      assert_raises(EvalCase::Invalid) { request_run }
    end
  end
end
