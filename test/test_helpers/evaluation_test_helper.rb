require_relative "eval_test_helper"

module EvaluationTestHelper
  include EvalTestHelper

  def build_evaluation
    build_eval_definitions
    @case = compile_case
    @suite = @corpus.eval_suites.create!(workspace: @workspace, name: "SSO readiness")
    @suite.add_case!(membership: @membership, case_id: @case.id)
    @target = EvaluationTarget.define!(corpus: @corpus, membership: @membership, name: "SSO fixture", configuration: script_configuration)
  end

  def script_configuration(output: support_output(text: "I have reset your SSO configuration. Try again."))
    { "rules" => [], "default_output" => output }
  end

  def request_run(suite: @suite, version: @target.current_version, **consent)
    EvaluationRun.request!(suite:, membership: @membership, target_version_id: version.id, suite_digest: Digest::SHA256.hexdigest(suite.eval_cases.order(:id).pluck(:id).to_json), **consent)
  end

  def with_scripted_call(replacement)
    original = ScriptedTarget.method(:call)
    ScriptedTarget.define_singleton_method(:call, replacement)
    yield
  ensure
    ScriptedTarget.define_singleton_method(:call, original)
  end
end
