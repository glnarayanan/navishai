require "test_helper"
require_relative "../test_helpers/eval_test_helper"

class CalibrationAccessTest < ActionDispatch::IntegrationTest
  include EvalTestHelper
  setup do
    build_eval_definitions
    @case = compile_case
    @check = @case.eval_case_checks.find_by!(requirement_kind: "actions")
    @set = CalibrationSet.define!(corpus: @corpus, membership: @membership, name: "Expiry calibration", grader_version_id: @action_grader.current_version_id)
    @sample = @set.add_sample!(membership: @membership, check_id: @check.id, cohort: "held_out", output: support_output(text: "<script>steal()</script> Please share expiry."))
    sign_in_as users(:owner)
  end

  test "creating a set through permitted parameters retains validation errors and freezes the chosen grader" do
    post workspace_corpus_calibration_sets_path(@workspace, @corpus), params: { calibration_set: { name: "", grader_version_id: @action_grader.current_version_id } }
    assert_response :unprocessable_content
    assert_select "[role=alert]", text: /Name can't be blank/
    post workspace_corpus_calibration_sets_path(@workspace, @corpus), params: { calibration_set: { name: "New review set", grader_version_id: @action_grader.current_version_id, workspace_id: workspaces(:beta_support).id } }
    set = CalibrationSet.order(:id).last
    assert_redirected_to workspace_corpus_calibration_set_path(@workspace, @corpus, set)
    assert_equal @workspace, set.workspace
    assert_equal @action_grader.current_version, set.grader_version
  end

  test "expert labels reveal predictions after review and malformed uploads retain input" do
    get sample_path
    assert_response :success
    assert_select "h2", text: "Machine prediction", count: 0
    assert_select "script", text: /steal/, count: 0
    assert_select "pre", text: /<script>steal\(\)<\/script>/, count: 1
    post label_workspace_corpus_calibration_set_calibration_sample_path(@workspace, @corpus, @set, @sample), params: { decision: "fail", rationale: "The tool call is missing." }
    assert_redirected_to sample_path
    follow_redirect!
    assert_select "h2", text: "Machine prediction"
    assert_select "textarea[name=rationale]", text: "The tool call is missing."
    post label_workspace_corpus_calibration_set_calibration_sample_path(@workspace, @corpus, @set, @sample), params: { decision: "pass", rationale: "Stale label" }
    assert_response :unprocessable_content
    assert_select "[role=alert]", text: /label changed/
    assert_select "textarea[name=rationale]", text: "Stale label"
    post workspace_corpus_calibration_set_calibration_samples_path(@workspace, @corpus, @set), params: { check_id: @check.id, cohort: "development", output: "{not valid" }
    assert_response :unprocessable_content
    assert_select "textarea[name=output]", text: "{not valid"
    assert_select "select[name=cohort] option[selected]", text: /Development/
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    assert_equal "[FILTERED]", filter.filter("rationale" => "company evidence").fetch("rationale")
  end

  test "calibration evidence reaches its exact document snapshot rather than its database ID" do
    @scenario.revise!(membership: @membership, base_version_id: @scenario.current_version_id, attributes: {},
      evidence_item_id: @knowledge.id, evidence_kind: "expectation", excerpt: "Request the certificate expiry date.")
    @scenario.review!(membership: @membership, version_id: @scenario.current_version_id, decision: "approve")
    evidence = @scenario.current_version.scenario_evidence.find_by!(kind: "expectation", corpus_item: @knowledge)
    fixed = compile_case(checks: @checks.map { |check| check.merge("scenario_evidence_id" => evidence.id) })
    @sample = @set.add_sample!(membership: @membership, check_id: fixed.eval_case_checks.find_by!(requirement_kind: "actions").id,
      cohort: "held_out", output: support_output(text: "Inspect our current playbook."))
    snapshot = @knowledge.source_snapshot
    assert_not_equal snapshot.id, snapshot.number
    get sample_path
    assert_response :success
    path = workspace_corpus_source_path(@workspace, @corpus, snapshot.source, snapshot: 1, page: 1, anchor: "record-#{@knowledge.id}")
    assert_select "a[href='#{path}']", text: "Supporting source snapshot"
    get path
    assert_response :success
    assert_select "article#record-#{@knowledge.id}", text: /Request the certificate expiry date/
  end

  test "review filters preserve full cohort counts and personal blindness without writes or jobs" do
    other = Membership.create!(workspace: @workspace, user: users(:teammate), role: :member)
    @sample.label!(membership: other, previous_id: nil, decision: "pass", rationale: "Another expert's interpretation stays off the queue.")
    differing = @set.add_sample!(membership: @membership, check_id: @check.id, cohort: "held_out", output: support_output(text: "Disagreement example"))
    differing.label!(membership: @membership, previous_id: nil, decision: "pass", rationale: "The answer satisfies the request without a reported tool.")
    aligned = @set.add_sample!(membership: @membership, check_id: @check.id, cohort: "held_out", output: support_output(text: "Agreed example", tools: [ "collect_expiry" ]))
    aligned.label!(membership: @membership, previous_id: nil, decision: "pass", rationale: "The required step appears.")
    @set.add_sample!(membership: @membership, check_id: @check.id, cohort: "development", output: support_output(text: "Separate development example"))
    path = workspace_corpus_calibration_set_path(@workspace, @corpus, @set)
    assert_no_difference [ "HumanLabel.count", "CalibrationPrediction.count", "CalibrationJudgeRun.count", "AuditEvent.count" ] do
      assert_no_enqueued_jobs do
        get path
        assert_response :success
        assert_select "#review-samples li" do |entries|
          assert_equal %w[unlabelled disagreement aligned], entries.map { |entry| entry["data-review-state"] }
        end
        assert_select "#review-samples li[data-review-state=unlabelled] a", text: "Sample #{@sample.id}"
        assert_select "#review-samples", text: /Another expert's interpretation/, count: 0
        get path, params: { review_state: "disagreement", cohort: "held_out" }
        assert_response :success
        assert_select "#review-samples li", count: 1
        assert_select "#review-samples li a", text: "Sample #{differing.id}"
        assert_select "#review-samples [role=status]", text: "1 of 3 cohort samples shown."
        assert_select "section > p", text: /3 samples · 3 labelled · 3 compared/
        assert_select "input[name=cohort][value=held_out]"
        get path, params: { review_state: "disputed" }
        assert_response :success
        assert_select "#review-samples li", count: 0
        assert_select "#review-samples", text: /No samples need this review focus/
        get path, params: { review_state: "<script>wrong()</script>", cohort: "development" }
        assert_response :success
        assert_select "#review-samples li", count: 1
        assert_select "select[name=review_state] option[selected]", count: 0
        assert_select "script", text: /wrong\(\)/, count: 0
        assert_select "section > p", text: /1 samples · 0 labelled · 0 compared/
      end
    end
  end

  test "viewer reads but cannot label or upload and foreign and expired records are hidden" do
    Membership.create!(workspace: @workspace, user: users(:teammate), role: :viewer)
    sign_in_as users(:teammate)
    get sample_path
    assert_response :success
    assert_select "input[type=submit]", count: 0
    get workspace_corpus_calibration_set_path(@workspace, @corpus, @set), params: { review_state: "aligned" }
    assert_response :success
    assert_select "#review-samples li", count: 1
    assert_select "#review-samples form", count: 0
    assert_select "#review-samples li[data-review-state='']", count: 1
    post label_workspace_corpus_calibration_set_calibration_sample_path(@workspace, @corpus, @set, @sample), params: {}
    assert_response :forbidden
    post workspace_corpus_calibration_set_calibration_samples_path(@workspace, @corpus, @set), params: {}
    assert_response :forbidden
    post workspace_corpus_calibration_sets_path(@workspace, @corpus), params: {}
    assert_response :forbidden
    sign_in_as users(:outsider)
    get sample_path
    assert_response :not_found
    get workspace_corpus_calibration_set_calibration_sample_path(workspaces(:beta_support), @corpus, @set, @sample)
    assert_response :not_found
    sign_in_as users(:owner)
    @knowledge.source_snapshot.source.update!(expires_at: 1.second.ago)
    get sample_path
    assert_response :not_found
    get workspace_corpus_calibration_set_path(@workspace, @corpus, @set)
    assert_response :not_found
  end

  private
    def sample_path
      workspace_corpus_calibration_set_calibration_sample_path(@workspace, @corpus, @set, @sample)
    end
end
