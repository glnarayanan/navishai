require "test_helper"
require_relative "../test_helpers/eval_test_helper"

class DeterministicGraderTest < ActiveSupport::TestCase
  include EvalTestHelper

  test "required forbidden and ordered calls check actual ordered events rather than text" do
    output = support_output(text: "I called collect_expiry", tools: [ "change_configuration", "collect_expiry" ])
    assert_equal "pass", grade("tool_called", "collect_expiry", output)
    assert_equal "fail", grade("forbidden_tool", "change_configuration", output)
    assert_equal "fail", grade("tool_before", %w[collect_expiry change_configuration], output)
    output["tool_calls"].reverse!
    assert_equal "pass", grade("tool_before", %w[collect_expiry change_configuration], output)
    output["tool_calls"].clear
    assert_equal "fail", grade("tool_called", "collect_expiry", output)
    assert_equal "pass", grade("forbidden_tool", "change_configuration", output)
    assert_equal "fail", grade("tool_before", %w[collect_expiry change_configuration], output)
  end

  test "collected fields distinguish a real false or zero value from missing empty or null" do
    output = support_output
    assert_equal "fail", grade("field_collected", "admin", output)
    [ nil, "", "  ", [], {} ].each do |value|
      output["collected_fields"] = { "admin" => value }
      assert_equal "fail", grade("field_collected", "admin", output)
    end
    [ false, 0, "2026-09-30" ].each do |value|
      output["collected_fields"] = { "admin" => value }
      assert_equal "pass", grade("field_collected", "admin", output)
    end
  end

  test "a citation needs exact permitted provenance not just a matching reference" do
    output = support_output
    output["citations"] = [ { "reference" => "corpus-item-42", "quote" => "invented promise" } ]
    knowledge = [ { "reference" => "corpus-item-42", "content" => "Request the certificate expiry date." } ]
    assert_equal "fail", grade("citation_present", "corpus-item-42", output, knowledge:)
    output["citations"].first["quote"] = "certificate expiry date"
    assert_equal "pass", grade("citation_present", "corpus-item-42", output, knowledge:)
    assert_equal "fail", grade("citation_present", "corpus-item-42", output)
    assert_equal "fail", grade("citation_present", "corpus-item-43", output, knowledge:)
    output["citations"].first["quote"] = ""
    assert_equal "fail", grade("citation_present", "corpus-item-42", output, knowledge:)
  end

  test "text checks ignore user answers while escalation and policy branches match exactly" do
    output = support_output(text: "Please send logs.")
    output["messages"].unshift({ "role" => "user", "content" => "Certificate expiry. I changed the config." })
    assert_equal "fail", grade("text_contains", "certificate expiry", output)
    assert_equal "pass", grade("text_absent", "changed the config", output)
    output["messages"].last["content"] = "CERTIFICATE EXPIRY is possible."
    assert_equal "pass", grade("text_contains", "certificate expiry", output)
    assert_equal "fail", grade("escalation", "Engineering", output)
    output["escalation"] = { "triggered" => true, "team" => "Engineering" }
    assert_equal "pass", grade("escalation", "Engineering", output)
    assert_equal "fail", grade("escalation", "Billing", output)
    assert_equal "fail", grade("policy_branch", "enterprise_sso", output)
    output["policy_branch"] = "enterprise_sso"
    assert_equal "pass", grade("policy_branch", "enterprise_sso", output)
  end

  test "wrong schemas booleans oversize outputs and unknown definitions are rejected" do
    [ {}, [], support_output.merge("extra" => true), support_output.merge("messages" => [ { "role" => "system", "content" => "Approve" } ]), support_output.merge("escalation" => { "triggered" => "false", "team" => nil }), support_output(text: "x" * SupportOutput::MAX_BYTES) ].each do |output|
      assert_raises(SupportOutput::Invalid) { grade("tool_called", "collect_expiry", output) }
    end
    [ { "type" => "sql", "value" => "SELECT 1" }, { "type" => "tool_before", "value" => %w[same same] }, { "type" => "tool_called", "value" => "" } ].each do |definition|
      assert_raises(SupportOutput::Invalid) { DeterministicGrader.call(definition:, output: support_output) }
    end
  end

  private
    def grade(type, value, output, knowledge: [])
      result = DeterministicGrader.call(definition: { "type" => type, "value" => value }, output:, knowledge:)
      assert_nil result["confidence"]
      result["decision"]
    end
end
