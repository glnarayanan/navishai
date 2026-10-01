require "test_helper"
require_relative "../test_helpers/evaluation_test_helper"

class MultiTurnChecksAccessTest < ActionDispatch::IntegrationTest
  include EvaluationTestHelper

  test "two line parser retains malformed create and revision values" do
    build_eval_definitions
    sign_in_as users(:owner)
    DeterministicGrader::RESPONSE_TYPES.each do |type|
      [ "anchor", "anchor\n\nphrase", "anchor\n ", "anchor\nphrase\nextra", "anchor\n#{'x' * 501}" ].each do |value|
        assert_no_difference "GraderVersion.count" do
          post workspace_corpus_graders_path(@workspace, @corpus), params: { grader: { name: "Turn check", kind: "deterministic", check_type: type, value: } }
        end
        assert_response :unprocessable_content
        assert_select "textarea[name='grader[value]']", text: value
        assert_select "select[name='grader[check_type]'] option[selected]", value: type
      end
      post workspace_corpus_graders_path(@workspace, @corpus), params: { grader: { name: "Turn check #{type}", kind: "deterministic", check_type: type, value: " anchor \r\n phrase " } }
      assert_response :see_other
      grader = @corpus.graders.order(:id).last
      assert_equal [ "anchor", "phrase" ], grader.current_version.definition["value"]
      version = grader.current_version
      patch workspace_corpus_grader_path(@workspace, @corpus, grader), params: { version_id: version.id, grader: { kind: "deterministic", check_type: type, value: "anchor\n\nphrase" } }
      assert_response :unprocessable_content
      assert_select "textarea[name='grader[value]']", text: "anchor\n\nphrase"
      assert_equal version.id, grader.reload.current_version_id
    end
  end

  test "existing v1 record compiles and runs unchanged under v2 implementation" do
    build_evaluation
    legacy = @corpus.graders.create!(workspace: @workspace, name: "Existing v1 text check")
    version = legacy.grader_versions.create!(workspace: @workspace, corpus: @corpus, created_by: @membership.user,
      number: 1, kind: "deterministic", definition: { "type" => "text_contains", "value" => "expiry" }, processing_version: "support-checks-v1", created_at: Time.current)
    legacy.update!(current_version: version)
    before = version.attributes
    fixed = compile_case(checks: @checks.map { |check| check.merge("grader_version_id" => version.id) })
    @suite.eval_suite_cases.delete_all(:delete_all)
    @suite.add_case!(membership: @membership, case_id: fixed.id)
    @target.revise!(membership: @membership, version_id: @target.current_version_id, configuration: script_configuration(output: support_output(text: "EXPIRY")))
    run = request_run
    EvaluationRunJob.perform_now(run.id)
    assert_equal "pass", run.reload.evaluation_run_items.sole.evaluation_result.status
    assert_equal before, version.reload.attributes
    assert_equal [ version.id ], fixed.eval_case_checks.pluck(:grader_version_id).uniq
  end
end
