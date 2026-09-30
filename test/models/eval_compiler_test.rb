require "test_helper"
require_relative "../test_helpers/eval_test_helper"

class EvalCompilerTest < ActiveSupport::TestCase
  include EvalTestHelper
  setup { build_eval_definitions }

  test "compilation freezes approval contract and bindings and repeats reuse the same definition" do
    item = compile_case
    assert_equal @scenario.current_version.latest_review, item.scenario_review
    assert_equal @scenario.current_version.requirements, item.contract
    assert_equal 2, item.eval_case_checks.count
    assert_equal @action_grader.current_version, item.eval_case_checks.find_by!(requirement_kind: "actions").grader_version
    assert_no_difference "EvalCase.count" do
      assert_equal item, compile_case(checks: @checks.reverse)
    end
    old_version = @action_grader.current_version
    @action_grader.revise!(membership: @membership, version_id: old_version.id, kind: "deterministic", definition: { "type" => "field_collected", "value" => "certificate_expiry" })
    assert_equal old_version, item.reload.eval_case_checks.find_by!(requirement_kind: "actions").grader_version
    next_checks = @checks.map { |check| check["requirement_kind"] == "actions" ? check.merge("grader_version_id" => @action_grader.current_version_id) : check }
    assert_equal 2, compile_case(checks: next_checks).number
    assert_no_difference "GraderVersion.count" do
      @action_grader.revise!(membership: @membership, version_id: @action_grader.current_version_id, kind: "deterministic", definition: @action_grader.current_version.definition)
    end
    assert_raises(EvalCase::Invalid) { @action_grader.revise!(membership: @membership, version_id: old_version.id, kind: "deterministic", definition: old_version.definition) }
    assert_raises(ActiveRecord::ReadOnlyRecord) { item.update!(number: 3) }
    [ [ EvalCase, item, { number: 3 } ], [ GraderVersion, old_version, { definition: {} } ], [ EvalCaseCheck, item.eval_case_checks.first, { requirement_index: 9 } ] ].each do |model, record, attributes|
      assert_raises(ActiveRecord::StatementInvalid) { model.transaction(requires_new: true) { model.where(id: record.id).update_all(attributes) } }
    end
  end

  test "all statements need exactly one bounded valid check before any case is stored" do
    invalid = [ [], @checks.first(1), @checks + [ @checks.first ], [ nil ], @checks.map { |check| check.merge("requirement_kind" => nil) }, @checks.map { |check| check.merge("requirement_index" => "0.9") }, @checks.map { |check| check.merge("requirement_index" => -1) }, @checks * 51 ]
    invalid.each do |checks|
      assert_no_difference "EvalCase.count" do
        assert_raises(EvalCase::Invalid) { compile_case(checks:) }
      end
    end
    assert_raises(EvalCase::Invalid) { compile_case(version_id: @scenario.scenario_versions.order(:number).first.id) }
    @scenario.review!(membership: @membership, version_id: @scenario.current_version_id, decision: "reject")
    assert_raises(EvalCase::Invalid) { compile_case }
  end

  test "foreign graders and wrong version evidence fail in service and database" do
    foreign_corpus = workspaces(:beta_support).corpora.create!(name: "Private")
    foreign = Grader.define!(corpus: foreign_corpus, membership: memberships(:outsider_beta), name: "Private rubric", kind: "deterministic", definition: { "type" => "escalation", "value" => "Engineering" })
    wrong_evidence = @scenario.scenario_versions.order(:number).first.scenario_evidence.sole
    [ @checks.map { |check| check.merge("grader_version_id" => foreign.current_version_id) }, @checks.map { |check| check.merge("scenario_evidence_id" => wrong_evidence.id) } ].each do |checks|
      assert_no_difference "EvalCase.count" do
        assert_raises(ActiveRecord::RecordNotFound) { compile_case(checks:) }
      end
    end
    item = compile_case
    template = item.eval_case_checks.first.attributes.except("id").merge("requirement_index" => 19)
    [ { "grader_version_id" => foreign.current_version_id }, { "scenario_evidence_id" => wrong_evidence.id } ].each do |mismatch|
      assert_raises(ActiveRecord::InvalidForeignKey) { EvalCaseCheck.transaction(requires_new: true) { EvalCaseCheck.create!(template.merge(mismatch)) } }
    end
    assert_raises(ActiveRecord::InvalidForeignKey) { Grader.transaction(requires_new: true) { @action_grader.update!(current_version: @outcome_grader.current_version) } }
    assert_raises(Current::RoleAccessDenied) { EvalCompiler.call(scenario: @scenario, membership: memberships(:outsider_beta), version_id: @scenario.current_version_id, checks: @checks) }
    @action_grader.reload
    assert_raises(ActiveRecord::RecordInvalid) { @action_grader.revise!(membership: @membership, version_id: @action_grader.current_version_id, kind: "rubric_judge", definition: { "rubric" => "Trust it", "confidence_threshold" => 1.1 }) }
  end

  test "target input excludes title hidden facts expectations and historical answer" do
    input = @scenario.current_version.target_input
    assert_equal %w[knowledge known_facts situation], input.keys.sort
    assert_equal({ "plan" => "enterprise", "idp" => "Okta" }, input["known_facts"])
    assert_equal [ { "reference" => "corpus-item-#{@knowledge.id}", "content" => "Request the certificate expiry date." } ], input["knowledge"]
    assert_not_includes input.to_json, "private answer"
    assert_not_includes input.to_json, "Identify certificate expiry as a possible cause."
    assert_not_includes input.to_json, "Engineering escalation if valid metadata returns 500."
  end

  test "approval revisions stale documents incomplete checks and expiry block suite admission" do
    item = compile_case
    suite = @corpus.eval_suites.create!(workspace: @workspace, name: "SSO baseline")
    suite.add_case!(membership: @membership, case_id: item.id)
    assert_no_difference "EvalSuiteCase.count" do
      suite.add_case!(membership: @membership, case_id: item.id)
    end
    item.eligible!
    Scenario.find(@scenario.id).revise!(membership: @membership, base_version_id: @scenario.current_version_id, attributes: { importance: "critical" })
    assert_raises(EvalCase::Invalid) { item.eligible! }
    @scenario.reload.review!(membership: @membership, version_id: @scenario.current_version_id, decision: "approve")
    checks = @checks.map { |check| check.merge("scenario_evidence_id" => @scenario.current_version.scenario_evidence.find_by!(kind: "expectation").id) }
    item = compile_case(checks:)
    CorpusIntake.call(corpus: @corpus, membership: @membership, name: "SSO playbook", kind: "document", bytes: "New rule: collect metadata instead.")
    assert_raises(EvalCase::Invalid) { item.eligible! }
    assert_raises(EvalCase::Invalid) { compile_case(checks:) }
    SourcePurge.call(source: @knowledge.source_snapshot.source, membership: @membership)
    assert_empty EvalCase.where(corpus: @corpus)
    assert_empty EvalCaseCheck.where(corpus: @corpus)
    assert_empty GraderVersion.where(corpus: @corpus)
    assert_empty Grader.where(corpus: @corpus)
    assert_empty suite.reload.eval_cases
  end

  test "the full hundred statement contract compiles without dropping later requirement kinds" do
    requirements = ScenarioVersion::REQUIREMENT_TYPES.to_h { |kind| [ kind, 20.times.map { |index| "#{kind} statement #{index}" } ] }
    @scenario.revise!(membership: @membership, base_version_id: @scenario.current_version_id, attributes: { requirements: })
    @scenario.review!(membership: @membership, version_id: @scenario.current_version_id, decision: "approve")
    checks = requirements.flat_map { |kind, statements| statements.each_index.map { |index| { "requirement_kind" => kind, "requirement_index" => index, "grader_version_id" => @outcome_grader.current_version_id, "scenario_evidence_id" => @scenario.current_version.scenario_evidence.first.id } } }
    item = compile_case(checks:)
    assert_equal 100, item.eval_case_checks.count
    assert_equal "grounding statement 19", item.eval_case_checks.find_by!(requirement_kind: "grounding", requirement_index: 19).requirement
    assert_raises(EvalCase::Invalid) { compile_case(checks: checks + [ checks.first ]) }
  end

  test "suite bound allows an existing fiftieth member but rejects a fifty first case" do
    suite = @corpus.eval_suites.create!(workspace: @workspace, name: "Bounded")
    50.times do |index|
      @action_grader.revise!(membership: @membership, version_id: @action_grader.current_version_id, kind: "deterministic", definition: { "type" => "tool_called", "value" => "collect_expiry_#{index}" })
      checks = @checks.map { |check| check["requirement_kind"] == "actions" ? check.merge("grader_version_id" => @action_grader.current_version_id) : check }
      @last_case = compile_case(checks:)
      suite.add_case!(membership: @membership, case_id: @last_case.id)
    end
    assert_equal 50, suite.eval_cases.count
    assert_no_difference "EvalSuiteCase.count" do
      suite.add_case!(membership: @membership, case_id: @last_case.id)
      assert_raises(EvalCase::Invalid) { suite.add_case!(membership: @membership, case_id: compile_case.id) }
    end
    @last_case.eval_case_checks.delete_all(:delete_all)
    assert_raises(EvalCase::Invalid) { @last_case.eligible! }
    travel 366.days do
      assert_raises(EvalCase::Invalid) { compile_case }
    end
  end
end
