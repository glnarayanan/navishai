require "test_helper"
require_relative "../test_helpers/evaluation_test_helper"

class ScriptedTargetTest < ActiveSupport::TestCase
  include EvaluationTestHelper

  test "first exact fact match wins and absent null false and numeric values stay distinct" do
    fallback = support_output(text: "No matching fact")
    configuration = { "rules" => [
      { "fact" => "admin", "equals" => false, "output" => support_output(text: "Non-admin") },
      { "fact" => "admin", "equals" => false, "output" => support_output(text: "Later rule") },
      { "fact" => "attempts", "equals" => 0, "output" => support_output(text: "No attempts") },
      { "fact" => "idp", "equals" => nil, "output" => support_output(text: "Unknown IdP") }
    ], "default_output" => fallback }
    [ [ { "admin" => false }, "Non-admin" ], [ { "admin" => true }, "No matching fact" ], [ { "attempts" => 0 }, "No attempts" ], [ { "attempts" => "0" }, "No matching fact" ], [ { "idp" => nil }, "Unknown IdP" ], [ {}, "No matching fact" ] ].each do |facts, expected|
      input = { "known_facts" => facts, "situation" => "Later rule", "knowledge" => [] }
      assert_equal expected, ScriptedTarget.call(configuration:, input:).fetch("messages").sole.fetch("content")
    end
    output = ScriptedTarget.call(configuration:, input: { "known_facts" => {} })
    output["messages"].clear
    assert_equal fallback, configuration["default_output"]
  end

  test "configuration is bounded declarative data and every fixture must match the output schema" do
    configuration = script_configuration
    rule = { "fact" => "plan", "equals" => "enterprise", "output" => support_output }
    ScriptedTarget.validate!(configuration.merge("rules" => [ rule ] * 20))
    [ nil, {}, configuration.merge("code" => "system('false')"), configuration.merge("rules" => [ rule ] * 21),
      configuration.merge("rules" => [ rule.merge("equals" => {}) ]), configuration.merge("rules" => [ rule.merge("fact" => "\0") ]),
      configuration.merge("default_output" => { "messages" => [] }), configuration.merge("rules" => [ rule.merge("output" => {}) ]),
      configuration.merge("rules" => [ rule.merge("equals" => "x" * 1.megabyte) ]) ].each do |invalid|
      assert_raises(SupportOutput::Invalid) { ScriptedTarget.validate!(invalid) }
    end
  end
end
