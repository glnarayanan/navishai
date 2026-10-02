require "test_helper"
require_relative "../test_helpers/judge_test_helper"

class JudgeAccessTest < ActionDispatch::IntegrationTest
  include JudgeTestHelper
  setup do
    build_judge_evaluation
    @sample = judge_sample
    sign_in_as users(:owner)
  end

  test "invalid configuration retains text and version token while a sample needs separate disclosure" do
    with_endpoint_approval do
      version_id = @outcome_grader.current_version_id
      assert_no_difference "GraderVersion.count" do
        patch workspace_corpus_grader_path(@workspace, @corpus, @outcome_grader), params: { version_id:, grader: { kind: "rubric_judge", rubric: "Keep this company rubric", confidence_threshold: "0.8", judge_configuration: "{unfinished" } }
        assert_response :unprocessable_content
        assert_select "textarea[name='grader[judge_configuration]']", text: "{unfinished"
        assert_select "input[name=version_id][value='#{version_id}']"
      end
      get workspace_corpus_calibration_set_calibration_sample_path(@workspace, @corpus, @judge_set, @sample)
      assert_select "input[name=judge_disclose][type=checkbox]"
      assert_select "label[for=judge_disclose]", text: /I approve sending/
      assert_select "h2", text: "Machine prediction", count: 0
      assert_no_difference "CalibrationJudgeRun.count" do
        post judge_path, params: { disclose: "1" }
        assert_response :unprocessable_content
        assert_select "[role=alert]", text: /Confirm disclosure/
      end
      assert_difference "CalibrationJudgeRun.count", 1 do
        post judge_path, params: { judge_disclose: "1" }
        assert_response :see_other
      end
      follow_redirect!
      assert_select "[role=status]", text: /Queued/
      assert_select "h2", text: "Machine prediction", count: 0
      assert_not_includes response.body, "test-only-token"
      filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
      assert_equal "[FILTERED]", filter.filter("judge_configuration" => "private settings")["judge_configuration"]
    end
  end

  test "viewers cannot execute or interrupt judges and foreign or expired records are hidden" do
    Membership.create!(workspace: @workspace, user: users(:teammate), role: :viewer)
    sign_in_as users(:teammate)
    get workspace_corpus_calibration_set_calibration_sample_path(@workspace, @corpus, @judge_set, @sample)
    assert_response :success
    assert_select "input[type=submit]", count: 0
    post judge_path, params: { judge_disclose: "1" }
    assert_response :forbidden
    post interrupt_judge_workspace_corpus_calibration_set_calibration_sample_path(@workspace, @corpus, @judge_set, @sample)
    assert_response :forbidden
    sign_in_as users(:outsider)
    post judge_path, params: { judge_disclose: "1" }
    assert_response :not_found
    post judge_workspace_corpus_calibration_set_calibration_sample_path(workspaces(:beta_support), @corpus, @judge_set, @sample), params: { judge_disclose: "1" }
    assert_response :not_found
    sign_in_as users(:owner)
    @knowledge.source_snapshot.source.update!(expires_at: 1.second.ago)
    post judge_path, params: { judge_disclose: "1" }
    assert_response :not_found
  end

  private
    def judge_path
      judge_workspace_corpus_calibration_set_calibration_sample_path(@workspace, @corpus, @judge_set, @sample)
    end
end
