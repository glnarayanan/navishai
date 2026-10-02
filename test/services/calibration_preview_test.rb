require "test_helper"
require_relative "../test_helpers/calibration_preview_fixture"

class CalibrationPreviewTest < ActiveSupport::TestCase
  include CalibrationPreviewFixture
  setup { build_calibration_preview }

  test "candidate exposes a missed failure without changing fixed predictions labels or held-out data" do
    before = @preview_set.calibration_samples.includes(:calibration_prediction, :human_labels).map do |sample|
      [ sample.attributes, sample.calibration_prediction.attributes, sample.human_labels.map(&:attributes) ]
    end
    original = CalibrationReport.call(set: @preview_set, cohort: "development")
    candidate = CalibrationReport.call(set: @preview_set, cohort: "development", candidate: @preview_candidate)
    assert_equal 3, candidate[:samples]
    assert_equal 3, candidate[:compared]
    assert_equal [ 2, 0, 0, 1 ], original.values_at(:true_positive, :false_positive, :false_negative, :true_negative)
    assert_equal [ 1, 0, 1, 1 ], candidate.values_at(:true_positive, :false_positive, :false_negative, :true_negative)
    assert_equal 0.5, candidate[:recall]
    assert_equal 1.0, original[:recall]
    assert_equal before, @preview_set.calibration_samples.includes(:calibration_prediction, :human_labels).map { |sample| [ sample.attributes, sample.calibration_prediction.attributes, sample.human_labels.map(&:attributes) ] }
    assert_equal [ 0, 1 ], CalibrationReport.call(set: @preview_set).values_at(:false_negative, :true_negative)
  end

  test "only a newer deterministic version of the same scoped grader can preview development" do
    assert_raises(EvalCase::Invalid) { CalibrationReport.call(set: @preview_set, candidate: @preview_candidate) }
    [ @preview_set.grader_version, @outcome_grader.current_version ].each do |version|
      assert_raises(EvalCase::Invalid) { CalibrationReport.call(set: @preview_set, cohort: "development", candidate: version) }
    end
    judge = @action_grader.revise!(membership: @membership, version_id: @action_grader.current_version_id, kind: "rubric_judge", definition: { "rubric" => "Synthetic rubric", "confidence_threshold" => 0.8 })
    assert_raises(EvalCase::Invalid) { CalibrationReport.call(set: @preview_set, cohort: "development", candidate: judge) }
    set, candidate = @preview_set, @preview_candidate
    build_calibration_preview
    assert_raises(EvalCase::Invalid) { CalibrationReport.call(set:, cohort: "development", candidate: @preview_candidate) }
    assert_equal 3, CalibrationReport.call(set:, cohort: "development", candidate:)[:samples]
  end

  test "preview retains dispute exclusions and latest authoritative corrections without rebinding labels" do
    other = @workspace.memberships.create!(user: users(:teammate), role: "member")
    sample = @preview_samples.last
    sample.label!(membership: other, previous_id: nil, decision: "fail", rationale: "Synthetic disagreement; do not call this truth.")
    candidate = CalibrationReport.call(set: @preview_set, cohort: "development", candidate: @preview_candidate)
    assert_equal 1, candidate[:disputed]
    assert_equal 2, candidate[:compared]
    first = @preview_samples.first
    label = first.human_labels.sole
    first.label!(membership: @membership, previous_id: label.id, decision: "pass", rationale: "Synthetic correction on the original fixed requirement.")
    corrected = CalibrationReport.call(set: @preview_set, cohort: "development", candidate: @preview_candidate)
    assert_equal [ 0, 1, 1, 0 ], corrected.values_at(:true_positive, :false_positive, :false_negative, :true_negative)
    assert_equal 2, first.human_labels.count
    assert_equal "fail", first.calibration_prediction.result["decision"]
    assert_equal @preview_set.grader_version_id, first.grader_version_id
  end

  test "new preview refuses stale approval evidence and expiry while fixed historical report stays fixed" do
    @scenario.review!(membership: @membership, version_id: @scenario.current_version_id, decision: "reject")
    assert_raises(EvalCase::Invalid) { CalibrationReport.call(set: @preview_set, cohort: "development", candidate: @preview_candidate) }
    assert_equal 2, CalibrationReport.call(set: @preview_set, cohort: "development")[:true_positive]
    @scenario.review!(membership: @membership, version_id: @scenario.current_version_id, decision: "approve")
    CorpusIntake.call(corpus: @corpus, membership: @membership, name: "SSO playbook", kind: "document", bytes: "Changed synthetic policy.")
    assert_raises(EvalCase::Invalid) { CalibrationReport.call(set: @preview_set, cohort: "development", candidate: @preview_candidate) }
    @knowledge.source_snapshot.source.update!(expires_at: 1.second.ago)
    assert_raises(EvalCase::Invalid) { CalibrationReport.call(set: @preview_set, cohort: "development", candidate: @preview_candidate) }
  end
end
