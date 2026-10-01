require "test_helper"
require_relative "../test_helpers/eval_test_helper"

class CalibrationCostAccessTest < ActionDispatch::IntegrationTest
  include EvalTestHelper

  setup do
    build_eval_definitions
    sign_in_as users(:owner)
    @values = { name: "Fixture assumptions", grader_version_id: @action_grader.current_version_id,
      false_positive_cost: "1.0000001", false_negative_cost: "7.5", error_cost_unit: "fixture units", error_cost_rationale: "Synthetic rationale <script>not executable</script>" }
    @path = workspace_corpus_calibration_sets_path(@workspace, @corpus)
  end

  test "creation retains raw invalid inputs and exposes exact attributed immutable assumptions" do
    assert_no_difference "CalibrationSet.count" do
      post @path, params: { calibration_set: @values }
      assert_response :unprocessable_content
    end
    assert_select "#error-cost-repair[role=alert]", text: /at most 6 decimal places/
    @values.except(:error_cost_rationale).each do |field, value|
      if field == :grader_version_id
        assert_select "select[name='calibration_set[#{field}]'] option[selected][value='#{value}']"
      else
        assert_select "input[name='calibration_set[#{field}]'][value='#{value}']"
      end
    end
    assert_select "textarea[name='calibration_set[error_cost_rationale]']", text: @values[:error_cost_rationale]
    post @path, params: { calibration_set: @values.merge(false_positive_cost: "0.000001", created_by_id: users(:outsider).id) }
    set = CalibrationSet.order(:id).last
    assert_redirected_to workspace_corpus_calibration_set_path(@workspace, @corpus, set)
    follow_redirect!
    assert_select "#error-cost-assumptions", text: /0.000001 fixture units/
    assert_select "#error-cost-assumptions", text: /expert ##{users(:owner).id}/
    assert_select "#error-cost-assumptions", text: /#{Regexp.escape(set.created_at.iso8601)}/
    assert_select "script", text: /not executable/, count: 0
    assert_select "#fixed-report", text: /Unknown — no comparable certain labels/
    assert_equal users(:owner), set.created_by
    assert_equal @action_grader.current_version, set.grader_version
    get @path
    assert_select "input[name='calibration_set[false_positive_cost]'][value]", count: 0
  end

  test "viewer reads supplied assumptions but cannot create foreign and expired sets stay hidden" do
    set = CalibrationSet.define!(corpus: @corpus, membership: @membership, **@values.merge(false_positive_cost: "1.25"))
    path = workspace_corpus_calibration_set_path(@workspace, @corpus, set)
    Membership.create!(workspace: @workspace, user: users(:teammate), role: :viewer)
    sign_in_as users(:teammate)
    get path
    assert_response :success
    assert_select "#error-cost-assumptions", text: /1.25 fixture units/
    post @path, params: { calibration_set: @values }
    assert_response :forbidden
    sign_in_as users(:outsider)
    get path
    assert_response :not_found
    sign_in_as users(:owner)
    @knowledge.source_snapshot.source.update!(expires_at: 1.second.ago)
    get path
    assert_response :not_found
    post @path, params: { calibration_set: @values }
    assert_response :not_found
  end
end
