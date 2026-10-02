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
end
