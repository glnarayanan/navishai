require "test_helper"
require_relative "../test_helpers/eval_test_helper"

class MultiTurnGraderTest < ActiveSupport::TestCase
  include EvalTestHelper

  test "only each anchored response counts not earlier user or unrelated later text" do
    transcripts = [
      [ [ "assistant", "expiry" ], [ "user", "new evidence" ], [ "assistant", "reset config" ] ],
      [ [ "user", "new evidence expiry" ], [ "assistant", "reset config" ] ],
      [ [ "user", "new evidence" ], [ "assistant", "reset config" ], [ "user", "other" ], [ "assistant", "expiry" ] ],
      [ [ "user", "new evidence" ], [ "assistant", "expiry" ], [ "user", "new evidence again" ], [ "assistant", "reset config" ] ]
    ]
    transcripts.each_with_index do |messages, index|
      output = transcript(messages)
      assert_equal "fail", decision("assistant_response_contains", output)
      assert_equal(index == 3 ? "fail" : "pass", decision("assistant_response_absent", output))
    end
    assert_equal "pass", DeterministicGrader.call(definition: { "type" => "text_contains", "value" => "expiry" }, output: transcript(transcripts.first))["decision"]
  end

  test "missing anchors and missing responses never pass either check" do
    [ [ [ "user", "other" ] ], [ [ "assistant", "expiry" ] ], [ [ "user", "new evidence" ] ],
      [ [ "user", "new evidence" ], [ "user", "other" ], [ "assistant", "expiry" ] ],
      [ [ "user", "new evidence" ], [ "assistant", "" ] ],
      [ [ "user", "new evidence" ], [ "assistant", "  " ], [ "assistant", "\n" ] ] ].each do |messages|
      DeterministicGrader::RESPONSE_TYPES.each { |type| assert_equal "fail", decision(type, transcript(messages)) }
    end
  end

  test "multiple assistant messages repeated anchors and Unicode case are supported" do
    output = transcript([ [ "user", "NÉW EVIDENCE" ], [ "assistant", "checking" ], [ "assistant", "ÉXPIRY" ], [ "user", "néw evidence again" ], [ "assistant", "éxpiry" ] ])
    assert_equal "pass", decision("assistant_response_contains", output, [ "néw evidence", "éxpiry" ])
    assert_equal "fail", decision("assistant_response_absent", output, [ "néw evidence", "éxpiry" ])
    assert_equal "pass", decision("assistant_response_absent", output, [ "néw evidence", "reset" ])
  end

  test "definitions require exactly two bounded nonblank strings but may repeat" do
    DeterministicGrader::RESPONSE_TYPES.each do |type|
      [ nil, "a\nb", [], [ "a" ], [ "a", "b", "c" ], [ "a", " " ], [ "a", 1 ], [ "a", "x" * 501 ], [ "a", " " + "x" * 500 ] ].each do |value|
        assert_not DeterministicGrader.valid_definition?({ "type" => type, "value" => value })
      end
      assert DeterministicGrader.valid_definition?({ "type" => type, "value" => [ "same", "same" ] })
      assert DeterministicGrader.valid_definition?({ "type" => type, "value" => [ "é" * 500, "x" * 500 ] })
    end
  end

  private
    def transcript(messages)
      support_output.merge("messages" => messages.map { |role, content| { "role" => role, "content" => content } })
    end

    def decision(type, output, value = [ "new evidence", "expiry" ])
      DeterministicGrader.call(definition: { "type" => type, "value" => value }, output:)["decision"]
    end
end
