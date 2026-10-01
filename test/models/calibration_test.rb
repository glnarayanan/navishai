require "test_helper"
require_relative "../test_helpers/eval_test_helper"

class CalibrationTest < ActiveSupport::TestCase
  include EvalTestHelper
  setup do
    build_eval_definitions
    @case = compile_case
    @check = @case.eval_case_checks.find_by!(requirement_kind: "actions")
    @set = CalibrationSet.define!(corpus: @corpus, membership: @membership, name: "Expiry collection", grader_version_id: @action_grader.current_version_id)
  end

  test "sample identity ignores JSON key order but cannot leak across cohorts or grader versions" do
    output = support_output(tools: [ "collect_expiry" ])
    sample = add_sample(output:)
    assert_equal "pass", sample.calibration_prediction.result.fetch("decision")
    assert_no_difference "CalibrationSample.count" do
      assert_equal sample, add_sample(output: output.to_a.reverse.to_h)
      assert_raises(EvalCase::Invalid) { add_sample(output:, cohort: "development") }
    end
    assert_equal output, sample.reload.output
    assert_raises(ActiveRecord::RecordNotFound) { @set.add_sample!(membership: @membership, check_id: @case.eval_case_checks.find_by!(requirement_kind: "outcomes").id, cohort: "held_out", output:) }
    @action_grader.revise!(membership: @membership, version_id: @action_grader.current_version_id, kind: "deterministic", definition: { "type" => "tool_called", "value" => "collect_metadata" })
    assert_equal 1, @set.reload.grader_version.number
    assert_equal "pass", sample.reload.calibration_prediction.result.fetch("decision")
    assert_raises(SupportOutput::Invalid) { add_sample(output: { "messages" => [] }) }
    assert_raises(ActiveRecord::RecordInvalid) { add_sample(cohort: "training") }
  end

  test "expert corrections are append only and stale writes cannot replace a new decision" do
    sample = add_sample
    first = label(sample, "pass")
    assert_raises(EvalCase::Invalid) { sample.label!(membership: @membership, previous_id: nil, decision: "fail", rationale: "Stale") }
    second = sample.label!(membership: @membership, previous_id: first.id, decision: "fail", rationale: "The required call is missing.")
    assert_equal [ first, second ], sample.human_labels.order(:id).to_a
    assert_equal [ second ], sample.latest_labels.to_a
    assert_no_difference "HumanLabel.count" do
      assert_equal second, sample.label!(membership: @membership, previous_id: second.id, decision: "fail", rationale: second.rationale)
    end
    [ [ CalibrationSet, @set, { name: "Rewrite" } ], [ CalibrationSample, sample, { cohort: "development" } ], [ CalibrationPrediction, sample.calibration_prediction, { result: {} } ], [ HumanLabel, first, { decision: "uncertain" } ] ].each do |model, record, attributes|
      assert_raises(ActiveRecord::ReadOnlyRecord) { record.update!(attributes) }
      assert_raises(ActiveRecord::StatementInvalid) { model.transaction(requires_new: true) { model.where(id: record.id).update_all(attributes) } }
    end
  end

  test "failure positive counts distinguish false alarms from missed failures and exclude development labels" do
    # TP=1, FP=2, FN=3, TN=1: reversing the positive class or merging cohorts fails.
    [ [ false, "fail" ], [ false, "pass" ], [ false, "pass" ], [ true, "fail" ], [ true, "fail" ], [ true, "fail" ], [ true, "pass" ] ].each_with_index do |(called, decision), index|
      label(add_sample(output: support_output(text: "Example #{index}", tools: called ? [ "collect_expiry" ] : [])), decision)
    end
    label(add_sample(cohort: "development", output: support_output(text: "Tuning example")), "fail")
    report = CalibrationReport.call(set: @set)
    assert_equal [ 1, 2, 3, 1 ], report.values_at(:true_positive, :false_positive, :false_negative, :true_negative)
    assert_equal 7, report[:compared]
    assert_in_delta 1.0 / 3, report[:precision]
    assert_in_delta 0.25, report[:recall]
    assert_in_delta 5.0 / 7, report[:disagreement_rate]
    assert_nil report[:inter_rater_agreement]
    assert_equal 1, CalibrationReport.call(set: @set, cohort: "development")[:true_positive]
  end

  test "disputed uncertain missing and abstaining predictions cannot create accuracy" do
    other = Membership.create!(workspace: @workspace, user: users(:teammate), role: :member)
    disputed = add_sample(output: support_output(text: "Disputed"))
    label(disputed, "fail")
    disputed.label!(membership: other, previous_id: nil, decision: "pass", rationale: "The answer asked for expiry, but no tool ran.")
    agreed = add_sample(output: support_output(text: "Agreed"))
    label(agreed, "fail")
    agreed.label!(membership: other, previous_id: nil, decision: "fail", rationale: "Missing diagnostic step.")
    label(add_sample(output: support_output(text: "Uncertain")), "uncertain")
    add_sample(output: support_output(text: "Not labelled"))
    report = CalibrationReport.call(set: @set)
    assert_equal [ 4, 3, 1, 1, 1 ], report.values_at(:samples, :labelled, :compared, :disputed, :uncertain)
    assert_equal 0.5, report[:inter_rater_agreement]
    assert_equal 2, report[:pairs]

    judge_set = CalibrationSet.define!(corpus: @corpus, membership: @membership, name: "Diagnosis", grader_version_id: @outcome_grader.current_version_id)
    sample = judge_set.add_sample!(membership: @membership, check_id: @case.eval_case_checks.find_by!(requirement_kind: "outcomes").id, cohort: "held_out", output: support_output)
    label(sample, "fail")
    report = CalibrationReport.call(set: judge_set)
    assert_equal 1, report[:unpredicted]
    assert_nil report[:precision]
    sample.create_calibration_prediction!(workspace: @workspace, corpus: @corpus, result: { "decision" => "abstain", "reason" => "Low confidence", "confidence" => 0.2 }, processing_version: "test-judge-v1", created_at: Time.current)
    report = CalibrationReport.call(set: judge_set)
    assert_equal 1, report[:abstained]
    assert_equal 0, report[:compared]
    assert_nil report[:recall]
  end

  test "whole cohort prediction totals stay separate from exclusive label exclusions" do
    other = Membership.create!(workspace: @workspace, user: users(:teammate), role: :member)
    set = CalibrationSet.define!(corpus: @corpus, membership: @membership, name: "Overlapping evidence states", grader_version_id: @outcome_grader.current_version_id)
    check = @case.eval_case_checks.find_by!(requirement_kind: "outcomes")
    disputed = nil
    [ [ "abstain", [ "fail", "pass" ] ], [ nil, [ "uncertain" ] ], [ "error", [] ],
      [ "abstain", [ "fail" ] ], [ nil, [ "pass" ] ], [ "fail", [ "pass" ] ],
      [ "pass", [ "fail" ] ], [ "pass", [] ] ].each_with_index do |(prediction, labels), index|
      sample = set.add_sample!(membership: @membership, check_id: check.id, cohort: "held_out", output: support_output(text: "Overlap #{index}"))
      sample.create_calibration_prediction!(workspace: @workspace, corpus: @corpus, result: { "decision" => prediction, "reason" => "Authored prediction" }, processing_version: "test-judge-v1", created_at: Time.current) if prediction
      label(sample, labels.first) if labels.any?
      if labels.size == 2
        sample.label!(membership: other, previous_id: nil, decision: labels.last, rationale: "Authored competing label.")
        disputed = sample
      end
    end
    development = set.add_sample!(membership: @membership, check_id: check.id, cohort: "development", output: support_output(text: "Separate development output"))
    label(development, "fail")
    report = CalibrationReport.call(set:)
    assert_equal [ 8, 6, 2, 2, 1, 1, 1, 1 ], report.values_at(:samples, :labelled, :compared, :unlabelled, :disputed, :uncertain, :abstained, :unpredicted)
    assert_equal({ "pass" => 2, "fail" => 1, "abstain" => 2, "error" => 1, "missing" => 2 }, report[:predictions])
    assert_equal [ 0, 1, 1, 0 ], report.values_at(:true_positive, :false_positive, :false_negative, :true_negative)
    assert_equal 1.0, report[:disagreement_rate]
    assert_equal 8, report[:predictions].values.sum
    assert_equal 8, report.values_at(:compared, :unlabelled, :disputed, :uncertain, :abstained, :unpredicted).sum
    assert_equal({ "pass" => 0, "fail" => 0, "abstain" => 0, "error" => 0, "missing" => 1 }, CalibrationReport.call(set:, cohort: "development")[:predictions])

    previous = disputed.latest_labels.find_by!(labelled_by: other.user)
    disputed.label!(membership: other, previous_id: previous.id, decision: "fail", rationale: "Authored correction after source review.")
    corrected = CalibrationReport.call(set:)
    assert_equal [ 0, 2 ], corrected.values_at(:disputed, :abstained)
    assert_equal report[:predictions], corrected[:predictions]
    assert_equal 2, corrected[:compared]
    assert_equal 3, disputed.human_labels.count
  end

  test "personal review states use latest labels without revealing other judgments before a first label" do
    other = Membership.create!(workspace: @workspace, user: users(:teammate), role: :member)
    aligned = add_sample(output: support_output(text: "Aligned failure"))
    label(aligned, "fail")
    disagreement = add_sample(output: support_output(text: "Machine missed failure", tools: [ "collect_expiry" ]))
    label(disagreement, "fail")
    uncertain = add_sample(output: support_output(text: "Expert needs evidence"))
    label(uncertain, "uncertain")
    disputed = add_sample(output: support_output(text: "Experts differ"))
    label(disputed, "fail")
    disputed.label!(membership: other, previous_id: nil, decision: "pass", rationale: "A competing expert interpretation.")
    blind = add_sample(output: support_output(text: "No personal label"))
    blind.label!(membership: other, previous_id: nil, decision: "uncertain", rationale: "Hidden until the reviewer decides.")
    development = add_sample(cohort: "development", output: support_output(text: "Development only"))
    report = CalibrationReport.call(set: @set, reviewer: @membership.user)
    states = report.fetch(:reviews).to_h { |entry| [ entry.fetch(:sample).id, entry.fetch(:state) ] }
    assert_equal({ aligned.id => "aligned", disagreement.id => "disagreement", uncertain.id => "uncertain", disputed.id => "disputed", blind.id => "unlabelled" }, states)
    assert_not states.key?(development.id)
    assert_equal [ 5, 2, 1, 2 ], report.values_at(:samples, :compared, :disputed, :uncertain)
    assert_equal 2, report.fetch(:reviews).find { |entry| entry[:sample] == disputed }.fetch(:label_count)

    # Corrections append history; old labels must not keep resolved samples in the queue.
    label(disagreement, "pass")
    correction = disputed.latest_labels.find_by!(labelled_by: other.user)
    disputed.label!(membership: other, previous_id: correction.id, decision: "fail", rationale: "Resolved using the company evidence.")
    latest = CalibrationReport.call(set: @set, reviewer: @membership.user).fetch(:reviews).to_h { |entry| [ entry[:sample].id, entry[:state] ] }
    assert_equal "aligned", latest.fetch(disagreement.id)
    assert_equal "aligned", latest.fetch(disputed.id)
    assert_equal "unlabelled", latest.fetch(blind.id)
    assert_equal "disputed", states.fetch(disputed.id)
    other_states = CalibrationReport.call(set: @set, reviewer: other.user).fetch(:reviews).to_h { |entry| [ entry[:sample].id, entry[:state] ] }
    assert_equal "unlabelled", other_states.fetch(aligned.id)
    assert_equal "uncertain", other_states.fetch(blind.id)
  end

  test "missing and abstaining predictions remain review work rather than machine agreement" do
    set = CalibrationSet.define!(corpus: @corpus, membership: @membership, name: "Offline rubric review", grader_version_id: @outcome_grader.current_version_id)
    check = @case.eval_case_checks.find_by!(requirement_kind: "outcomes")
    missing = set.add_sample!(membership: @membership, check_id: check.id, cohort: "held_out", output: support_output(text: "Missing prediction"))
    abstaining = set.add_sample!(membership: @membership, check_id: check.id, cohort: "held_out", output: support_output(text: "Abstaining prediction"))
    [ missing, abstaining ].each { |sample| label(sample, "fail") }
    abstaining.create_calibration_prediction!(workspace: @workspace, corpus: @corpus, result: { "decision" => "abstain", "reason" => "Insufficient evidence" }, processing_version: "test-judge-v1", created_at: Time.current)
    report = CalibrationReport.call(set:, reviewer: @membership.user)
    assert_equal [ "uncompared", "uncompared" ], report.fetch(:reviews).map { |entry| entry[:state] }
    assert_equal [ 2, 0, 1, 1 ], report.values_at(:samples, :compared, :unpredicted, :abstained)
    assert_nil report[:precision]
  end

  test "database rejects foreign or wrong grader links and expiry blocks writes before purge" do
    foreign = workspaces(:beta_support).corpora.create!(name: "Other company")
    grader = Grader.define!(corpus: foreign, membership: memberships(:outsider_beta), name: "Private", kind: "deterministic", definition: { "type" => "text_absent", "value" => "private" })
    assert_raises(ActiveRecord::RecordNotFound) { CalibrationSet.define!(corpus: @corpus, membership: @membership, name: "Foreign", grader_version_id: grader.current_version_id) }
    sample = add_sample
    attributes = sample.attributes.except("id").merge("output_digest" => "different")
    [ { "workspace_id" => foreign.workspace_id }, { "grader_version_id" => @outcome_grader.current_version_id } ].each do |mismatch|
      assert_raises(ActiveRecord::InvalidForeignKey) { CalibrationSample.transaction(requires_new: true) { CalibrationSample.create!(attributes.merge(mismatch)) } }
    end
    assert_raises(Current::RoleAccessDenied) { sample.label!(membership: memberships(:outsider_beta), previous_id: nil, decision: "pass", rationale: "Foreign") }
    label(sample, "fail")
    @knowledge.source_snapshot.source.update!(expires_at: 1.second.ago)
    assert_raises(EvalCase::Invalid) { label(sample, "pass") }
    assert_raises(EvalCase::Invalid) { add_sample }
    SourcePurge.call(source: @knowledge.source_snapshot.source, membership: @membership)
    assert_empty CalibrationSet.where(corpus: @corpus)
    assert_empty CalibrationSample.where(corpus: @corpus)
    assert_empty CalibrationPrediction.where(corpus: @corpus)
    assert_empty HumanLabel.where(corpus: @corpus)
  end

  test "hundred sample bound permits repeat imports but rejects the next distinct output" do
    100.times { |index| add_sample(output: support_output(text: "Output #{index}")) }
    assert_equal 100, @set.calibration_samples.count
    assert_no_difference "CalibrationSample.count" do
      add_sample(output: support_output(text: "Output 99"))
      assert_raises(EvalCase::Invalid) { add_sample(output: support_output(text: "Output 100")) }
    end
  end

  private
    def add_sample(output: support_output, cohort: "held_out")
      @set.add_sample!(membership: @membership, check_id: @check.id, cohort:, output:)
    end

    def label(sample, decision)
      previous = sample.human_labels.where(labelled_by: @membership.user).order(:id).last
      sample.label!(membership: @membership, previous_id: previous&.id, decision:, rationale: "Expert evidence: #{decision}.")
    end
end
