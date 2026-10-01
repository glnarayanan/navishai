require "test_helper"
require_relative "../test_helpers/evaluation_test_helper"

class ResultCalibrationAccessTest < ActionDispatch::IntegrationTest
  include EvaluationTestHelper
  setup do
    build_evaluation
    @run = request_run
    EvaluationRunJob.perform_now(@run.id)
    @result = @run.evaluation_results.sole
    @check = @case.eval_case_checks.find_by!(requirement_kind: "actions")
    @set = CalibrationSet.define!(corpus: @corpus, membership: @membership, name: "Selected failures", grader_version_id: @action_grader.current_version_id)
    sign_in_as users(:owner)
  end

  test "result selection fixed output failed recovery and blind then revealed provenance" do
    get workspace_corpus_evaluation_result_path(@workspace, @corpus, @result)
    assert_response :success
    assert_select "a[href='#{new_workspace_corpus_calibration_set_calibration_sample_path(@workspace, @corpus, @set, evaluation_result_id: @result.id)}']"
    capture("result-selection")
    get new_workspace_corpus_calibration_set_calibration_sample_path(@workspace, @corpus, @set), params: { evaluation_result_id: @result.id }
    assert_response :success
    assert_select "textarea[name=output]", count: 0
    assert_select "select[name=cohort] option[selected]", count: 0
    capture("fixed-result-form")
    post samples_path, params: { evaluation_result_id: @result.id, check_id: @check.id, cohort: "" }
    assert_response :unprocessable_content
    assert_select "input[name=evaluation_result_id][value='#{@result.id}']"
    assert_select "select[name=check_id] option[selected][value='#{@check.id}']"
    capture("failed-form")
    assert_no_enqueued_jobs do
      post samples_path, params: { evaluation_result_id: @result.id, check_id: @check.id, cohort: "development", output: "forged invalid JSON" }
    end
    assert_response :see_other
    sample = @set.calibration_samples.sole
    assert_equal @result.output, sample.output
    follow_redirect!
    result_path = workspace_corpus_evaluation_result_path(@workspace, @corpus, @result)
    assert_select "a[href='#{result_path}']", count: 0
    capture("blind-provenance")
    post label_workspace_corpus_calibration_set_calibration_sample_path(@workspace, @corpus, @set, sample), params: { decision: "fail", rationale: "Missing required tool." }
    follow_redirect!
    assert_select "a[href='#{result_path}']", text: "Exact saved result"
    capture("revealed-provenance")
    Membership.create!(workspace: @workspace, user: users(:teammate), role: :viewer)
    sign_in_as users(:teammate)
    get workspace_corpus_calibration_set_calibration_sample_path(@workspace, @corpus, @set, sample)
    assert_select "a[href='#{result_path}']"
    capture("viewer-provenance")
    post samples_path, params: { evaluation_result_id: @result.id, check_id: @check.id, cohort: "development" }
    assert_response :forbidden
  end

  test "error and viewer results have no sample selection and scoped accesses stay hidden" do
    run = request_run
    with_scripted_call(->(**) { {} }) { EvaluationRunJob.perform_now(run.id) }
    error = run.evaluation_results.sole
    get workspace_corpus_evaluation_result_path(@workspace, @corpus, error)
    assert_response :success
    assert_select "a", text: /Select Selected failures/, count: 0
    capture("retained-error-no-output")
    post samples_path, params: { evaluation_result_id: error.id, check_id: @check.id, cohort: "held_out" }
    assert_response :unprocessable_content
    assert_select "[role=alert]", text: /no usable output/
    Membership.create!(workspace: @workspace, user: users(:teammate), role: :viewer)
    sign_in_as users(:teammate)
    get workspace_corpus_evaluation_result_path(@workspace, @corpus, @result)
    assert_select "a", text: /Select Selected failures/, count: 0
    capture("viewer-result")
    sign_in_as users(:outsider)
    get new_workspace_corpus_calibration_set_calibration_sample_path(@workspace, @corpus, @set), params: { evaluation_result_id: @result.id }
    assert_response :not_found
    sign_in_as users(:owner)
    @knowledge.source_snapshot.source.update!(expires_at: 1.second.ago)
    post samples_path, params: { evaluation_result_id: @result.id, check_id: @check.id, cohort: "development" }
    assert_response :not_found
  end

  private
    def samples_path
      workspace_corpus_calibration_set_calibration_samples_path(@workspace, @corpus, @set)
    end

    def capture(name)
      return unless ENV["RESULT_CALIBRATION_CAPTURE_DIR"]
      File.write(File.join(ENV.fetch("RESULT_CALIBRATION_CAPTURE_DIR"), "#{name}.html"), response.body.sub("<head>", '<head><meta charset="utf-8">'))
    end
end
