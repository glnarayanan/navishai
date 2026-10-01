require "test_helper"
require_relative "../test_helpers/eval_test_helper"

class CalibrationCostTest < ActiveSupport::TestCase
  include EvalTestHelper

  setup do
    build_eval_definitions
    @case = compile_case
    @check = @case.eval_case_checks.find_by!(requirement_kind: "actions")
    @costs = { false_positive_cost: "1.25", false_negative_cost: "7.5", error_cost_unit: "fixture units", error_cost_rationale: "Synthetic asymmetric assumptions, not business costs." }
  end

  test "raw validation refuses casting rounding partial nonfinite and excessive inputs" do
    [ "-1", "NaN", "Infinity", "-Infinity", "1e2", "1.0000001", "1000000000000", "bad", "1,25", ".5", "1.", " 1", "", nil ].each do |value|
      assert_raises(ActiveRecord::RecordInvalid, value.inspect) { define_set(**@costs.merge(false_positive_cost: value)) }
    end
    @costs.each_key do |field|
      assert_raises(ActiveRecord::RecordInvalid) { define_set(**@costs.merge(field => " \t\n")) }
    end
    assert_raises(ActiveRecord::RecordInvalid) { define_set(**@costs.merge(error_cost_unit: "u" * 121)) }
    assert_raises(ActiveRecord::RecordInvalid) { define_set(**@costs.merge(error_cost_rationale: "r" * 2001)) }
    assert_raises(ActiveRecord::RecordInvalid) { define_set(**@costs.merge(error_cost_unit: "unit\0")) }
    assert_raises(ActiveRecord::RecordInvalid) { define_set(**@costs.merge(error_cost_rationale: "reason\0")) }
    assert_equal BigDecimal("999999999999.999999"), define_set(**@costs.merge(false_positive_cost: "999999999999.999999")).false_positive_cost
    unknown = define_set(**@costs.transform_values { " \t\n" })
    assert_not unknown.error_costs_supplied?
    assert_nil unknown.error_cost_unit
    assert_nil CalibrationReport.call(set: unknown)[:assumed_cost]
  end

  test "exact asymmetric totals cohorts candidate and appended labels remain independent" do
    set = define_set(**@costs)
    originals = []
    [ [ false, "pass" ], [ false, "pass" ], [ true, "fail" ], [ true, "fail" ], [ true, "fail" ] ].each_with_index do |(called, decision), index|
      sample = sample(set, text: "Observed #{index}", called:)
      originals << sample.label!(membership: @membership, previous_id: nil, decision:, rationale: "Fixture expert label.")
    end
    development = sample(set, text: "Development", called: false, cohort: "development")
    development.label!(membership: @membership, previous_id: nil, decision: "pass", rationale: "Fixture expert label.")
    report = CalibrationReport.call(set:)
    assert_equal [ 2, 3, 5 ], report.values_at(:false_positive, :false_negative, :compared)
    assert_equal BigDecimal("25"), report[:assumed_cost]
    assert_equal BigDecimal("1.25"), CalibrationReport.call(set:, cohort: "development")[:assumed_cost]
    @action_grader.revise!(membership: @membership, version_id: @action_grader.current_version_id, kind: "deterministic", definition: { "type" => "text_contains", "value" => "Development" })
    assert_equal BigDecimal("0"), CalibrationReport.call(set:, cohort: "development", candidate: @action_grader.current_version)[:assumed_cost]
    assert_equal "fail", development.reload.calibration_prediction.result.fetch("decision")
    originals.first.calibration_sample.label!(membership: @membership, previous_id: originals.first.id, decision: "fail", rationale: "Appended correction.")
    assert_equal BigDecimal("23.75"), CalibrationReport.call(set:)[:assumed_cost]
    assert_equal "pass", originals.first.reload.decision
    assert_equal BigDecimal("25"), report[:assumed_cost]
    assert_equal BigDecimal("1.25"), set.reload.false_positive_cost
    assert_equal @membership.user, set.created_by
    assert_equal 1, set.grader_version.number
  end

  test "excluded samples cannot supply a cost and zero remains known only with comparisons" do
    set = define_set(**@costs)
    assert_nil CalibrationReport.call(set:)[:assumed_cost]
    other = Membership.create!(workspace: @workspace, user: users(:teammate), role: :member)
    disputed = sample(set, text: "Disputed")
    disputed.label!(membership: @membership, previous_id: nil, decision: "pass", rationale: "Fixture interpretation.")
    disputed.label!(membership: other, previous_id: nil, decision: "fail", rationale: "Fixture dispute.")
    uncertain = sample(set, text: "Uncertain")
    uncertain.label!(membership: @membership, previous_id: nil, decision: "uncertain", rationale: "Insufficient fixture evidence.")
    sample(set, text: "Unlabelled")
    assert_nil CalibrationReport.call(set:)[:assumed_cost]
    comparable = sample(set, text: "Comparable")
    comparable.label!(membership: @membership, previous_id: nil, decision: "pass", rationale: "Fixture label.")
    report = CalibrationReport.call(set:)
    assert_equal [ 1, 1, 1 ], report.values_at(:compared, :disputed, :uncertain)
    assert_equal BigDecimal("1.25"), report[:assumed_cost]
    zero = define_set(**@costs.merge(false_positive_cost: "0", false_negative_cost: "0"))
    assert_nil CalibrationReport.call(set: zero)[:assumed_cost]
    sample(zero, text: "Zero-cost comparison").label!(membership: @membership, previous_id: nil, decision: "pass", rationale: "Fixture label.")
    assert_equal BigDecimal("0"), CalibrationReport.call(set: zero)[:assumed_cost]
    unknown = define_set
    sample(unknown, text: "Unknown-cost comparison").label!(membership: @membership, previous_id: nil, decision: "pass", rationale: "Fixture label.")
    assert_equal 1, CalibrationReport.call(set: unknown)[:compared]
    assert_nil CalibrationReport.call(set: unknown)[:assumed_cost]
    judge = define_set(**@costs, grader_version_id: @outcome_grader.current_version_id)
    check = @case.eval_case_checks.find_by!(requirement_kind: "outcomes")
    missing = judge.add_sample!(membership: @membership, check_id: check.id, cohort: "held_out", output: support_output)
    missing.label!(membership: @membership, previous_id: nil, decision: "fail", rationale: "Fixture label.")
    assert_nil CalibrationReport.call(set: judge)[:assumed_cost]
    missing.create_calibration_prediction!(workspace: @workspace, corpus: @corpus, result: { "decision" => "abstain" }, processing_version: "fixture", created_at: Time.current)
    assert_equal 1, CalibrationReport.call(set: judge)[:abstained]
    assert_nil CalibrationReport.call(set: judge)[:assumed_cost]
  end

  test "SQL rejects partial negative nonfinite blank bounded groups and immutable updates" do
    set = define_set(**@costs)
    attributes = set.attributes.except("id")
    [ { false_positive_cost: nil }, { false_negative_cost: nil }, { error_cost_unit: nil }, { error_cost_rationale: nil },
      { false_positive_cost: "-1" }, { false_negative_cost: "-1" }, { false_positive_cost: "NaN" }, { false_negative_cost: "NaN" }, { false_positive_cost: "Infinity" }, { false_negative_cost: "-Infinity" },
      { false_positive_cost: "1.0000001" }, { false_negative_cost: "7.5000001" }, { false_positive_cost: "1000000000000" },
      { error_cost_unit: " \t\n" }, { error_cost_rationale: " " }, { error_cost_unit: "u" * 121 }, { error_cost_rationale: "r" * 2001 } ].each do |invalid|
      assert_raises(ActiveRecord::StatementInvalid) do
        CalibrationSet.transaction(requires_new: true) do
          connection = CalibrationSet.connection
          values = attributes.merge(invalid.stringify_keys)
          columns = values.keys.map { |key| connection.quote_column_name(key) }.join(", ")
          literals = values.values.map { |value| connection.quote(value) }.join(", ")
          connection.execute("INSERT INTO calibration_sets (#{columns}) VALUES (#{literals})")
        end
      end
    end
    assert_raises(ActiveRecord::ReadOnlyRecord) { set.update!(false_positive_cost: "2") }
    assert_raises(ActiveRecord::StatementInvalid) do
      CalibrationSet.transaction(requires_new: true) { CalibrationSet.where(id: set.id).update_all(false_positive_cost: "2") }
    end
    assert_equal BigDecimal("1.25"), set.reload.false_positive_cost
  end

  private
    def define_set(**costs)
      CalibrationSet.define!(corpus: @corpus, membership: @membership, name: "Fixture costs", grader_version_id: costs.delete(:grader_version_id) || @action_grader.current_version_id, **costs)
    end

    def sample(set, text:, called: false, cohort: "held_out")
      set.add_sample!(membership: @membership, check_id: @check.id, cohort:, output: support_output(text:, tools: called ? [ "collect_expiry" ] : []))
    end
end
