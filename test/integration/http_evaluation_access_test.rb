require "test_helper"
require_relative "../test_helpers/evaluation_test_helper"
require_relative "../test_helpers/http_target_test_helper"

class HttpEvaluationAccessTest < ActionDispatch::IntegrationTest
  include EvaluationTestHelper
  include HttpTargetTestHelper
  setup do
    build_evaluation
    sign_in_as users(:owner)
  end

  test "HTTP form retains adapter and invalid input while secret approval and run disclosure stay explicit" do
    path = workspace_corpus_evaluation_targets_path(@workspace, @corpus)
    with_endpoint_approval do
      assert_no_difference "EvaluationTarget.count" do
        post path, params: { name: "Endpoint candidate", adapter: "http", configuration: '{"endpoint":"https://unapproved.example.test/evaluate"}' }
        assert_response :unprocessable_content
        assert_select "select[name=adapter] option[selected][value=http]"
        assert_select "textarea[name=configuration]", text: /unapproved.example.test/
        assert_select "[role=alert]", text: /not approved/
      end
      post path, params: { name: "HTTP readiness", adapter: "http", configuration: { endpoint: HTTP_ENDPOINT }.to_json }
      assert_response :see_other
      target = EvaluationTarget.order(:id).last
      follow_redirect!
      assert_select "h1", text: "HTTP readiness"
      assert_select "p[role=status]", text: /only after you confirm disclosure/
      assert_not_includes response.body, "test-only-token"
      assert_not_includes target.current_version.attributes.to_json, "test-only-token"
      run_path = workspace_corpus_evaluation_runs_path(@workspace, @corpus)
      run_params = { suite_id: @suite.id, target_version_id: target.current_version_id }
      assert_no_difference "EvaluationRun.count" do
        post run_path, params: run_params
        follow_redirect!
        assert_select "[role=alert]", text: /Confirm disclosure/
        assert_select "input[type=checkbox][name=disclose]"
        assert_select "label[for=disclose]", text: /I approve sending/
        assert_includes response.body, HTTP_ENDPOINT
      end
      assert_difference "EvaluationRun.count", 1 do
        post run_path, params: run_params.merge(disclose: "1", suite_digest: Digest::SHA256.hexdigest([ @case.id ].to_json))
        assert_response :see_other
      end
      follow_redirect!
      assert_select "p[role=status]", text: /HTTP run/
      assert_not_includes response.body, "test-only-token"
      assert_not_includes AuditEvent.where(workspace: @workspace).pluck(:metadata).to_json, "test-only-token"
    end
  end
end
