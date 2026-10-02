module HttpTargetTestHelper
  HTTP_ENDPOINT = "https://eval.example.test/evaluate"

  def with_endpoint_approval(workspace_id: @workspace.id, endpoint: HTTP_ENDPOINT)
    original = ENV["NAVISHAI_EVALUATION_ENDPOINTS"]
    ENV["NAVISHAI_EVALUATION_ENDPOINTS"] = [ { workspace_id:, endpoint:, bearer_token: "test-only-token" } ].to_json
    yield
  ensure
    original ? ENV["NAVISHAI_EVALUATION_ENDPOINTS"] = original : ENV.delete("NAVISHAI_EVALUATION_ENDPOINTS")
  end

  def with_test_method(receiver, name, replacement)
    original = receiver.method(name)
    receiver.define_singleton_method(name) { |*args, **kwargs, &block| replacement.call(*args, **kwargs, &block) }
    yield
  ensure
    receiver.define_singleton_method(name, original)
  end

  def define_http_target
    EvaluationTarget.define!(corpus: @corpus, membership: @membership, name: "Candidate HTTP agent", adapter: "http", configuration: { "endpoint" => HTTP_ENDPOINT })
  end

  def add_unseen_http_case
    child = @scenario.variant!(membership: @membership, version_id: @scenario.current_version_id, variable: "idp", after: "Entra",
      reason: "Cover a second company-supported IdP.", expected_difference: "Request Entra certificate evidence instead of Okta evidence.")
    child.revise!(membership: @membership, base_version_id: child.current_version_id, attributes: { situation: "Entra sign-in stopped after certificate rotation." })
    child.review!(membership: @membership, version_id: child.current_version_id, decision: "approve")
    checks = @checks.map { |check| check.merge("scenario_evidence_id" => child.current_version.scenario_evidence.find_by!(kind: "expectation").id) }
    item = EvalCompiler.call(scenario: child, membership: @membership, version_id: child.current_version_id, checks:)
    @suite.add_case!(membership: @membership, case_id: item.id)
    item
  end
end
