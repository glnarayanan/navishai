require "test_helper"
require_relative "../test_helpers/assumption_impact_test_helper"

class AssumptionChangeAnalysisTest < ActiveSupport::TestCase
  include AssumptionImpactTestHelper
  setup { build_change_impact }

  test "wire excludes local provenance but retains complete affected-assumption data" do
    input = impact_preview
    payload = AssumptionChangeAnalysis.payload(input, impact_configuration)
    wire = payload.fetch("input")
    assert_equal %w[after before historical scenarios], wire.keys.sort
    assert_equal "source-assumption-impact-v2", payload.fetch("schema")
    %w[before after].each do |side|
      assert_equal %w[content context title], wire.fetch(side).keys.sort
      assert_equal input.dig(side, "content"), wire.dig(side, "content")
      assert_equal @membership.user_id, input.dig(side, "imported_by_id")
      assert input.dig(side, "intake_time")
    end
    wire.fetch("scenarios").each do |entry|
      local = input.fetch("scenarios").find { |candidate| candidate.fetch("reference") == entry.fetch("reference") }
      assert_equal %w[assumptions reference title], entry.keys.sort
      assert_equal local.fetch("assumptions"), entry.fetch("assumptions")
      assert local.fetch("created_by_id")
      assert local.fetch("created_at")
    end
    assert_equal @source.expires_at.iso8601(6), input.fetch("source_expires_at")
    assert_equal [ "Business excludes SAML" ], wire.fetch("scenarios").find { |entry| entry["reference"] == "scenario-version-#{@version.id}" }.dig("assumptions", "hidden_facts").values
  end

  test "every proposal needs exact fixed version field and before after assumption quotes" do
    input = impact_preview
    assert_equal impact_response, AssumptionChangeAnalysis.validate_response!(impact_response, input:, model: impact_configuration.fetch("model"))
    %w[reference field before_quote after_quote assumption_quote uncertainty reason].each do |field|
      invalid = impact_response.deep_dup
      invalid["affected"][0][field] = field.in?(%w[reason uncertainty]) ? " " : "invented"
      assert_raises(SupportOutput::Invalid, field) { AssumptionChangeAnalysis.validate_response!(invalid, input:, model: impact_configuration.fetch("model")) }
    end
    invalid = impact_response.deep_dup
    invalid["affected"] << invalid["affected"][0].deep_dup
    assert_raises(SupportOutput::Invalid) { AssumptionChangeAnalysis.validate_response!(invalid, input:, model: impact_configuration.fetch("model")) }
    [ { "decision" => "pass" }, { "model" => "fallback" }, { "schema" => "other" }, { "coverage" => 100 }, { "cost" => { "currency" => "USD", "micro_units" => -1 } }, { "affected" => [] }, { "affected" => nil } ].each do |change|
      assert_raises(SupportOutput::Invalid) { AssumptionChangeAnalysis.validate_response!(impact_response.merge(change), input:, model: impact_configuration.fetch("model")) }
    end
    invalid = impact_response.merge("decision" => "abstain")
    assert_raises(SupportOutput::Invalid) { AssumptionChangeAnalysis.validate_response!(invalid, input:, model: impact_configuration.fetch("model")) }
  end

  test "twenty quoted eligible proposals fit but twenty-one never truncate" do
    input = impact_preview
    example = input.fetch("scenarios").find { |entry| entry.fetch("version_id") == @version.id }
    input["scenarios"] = (1..21).map { |id| example.merge("version_id" => id, "reference" => "scenario-version-#{id}") }
    response = impact_response
    response["affected"] = (1..20).map { |id| response.fetch("affected").sole.merge("reference" => "scenario-version-#{id}") }
    assert_equal 20, AssumptionChangeAnalysis.validate_response!(response, input:, model: impact_configuration.fetch("model")).fetch("affected").size
    response["affected"] << response.fetch("affected").first.merge("reference" => "scenario-version-21")
    assert_raises(SupportOutput::Invalid) { AssumptionChangeAnalysis.validate_response!(response, input:, model: impact_configuration.fetch("model")) }
  end

  test "complete UTF-8 byte and protocol overhead boundaries refuse without truncation" do
    @after = import_impact_document("Business now supports SAML. <b>界</b> & quotes: \"confirmed\".")
    input = impact_preview
    size = JSON.generate(AssumptionChangeAnalysis.wire_input(input)).bytesize
    stub_const(AssumptionChangeAnalysis, :MAX_INPUT_BYTES, size) { assert_equal input, impact_preview }
    stub_const(AssumptionChangeAnalysis, :MAX_INPUT_BYTES, size - 1) { assert_raises(CorpusIntake::Invalid) { impact_preview } }
    payload_size = JSON.generate(AssumptionChangeAnalysis.payload(input, impact_configuration)).bytesize
    stub_const(AssumptionChangeAnalysis, :MAX_INPUT_BYTES, payload_size) { AssumptionChangeAnalysis.check_payload!(input, impact_configuration) }
    stub_const(AssumptionChangeAnalysis, :MAX_INPUT_BYTES, payload_size - 1) { assert_raises(CorpusIntake::Invalid) { AssumptionChangeAnalysis.check_payload!(input, impact_configuration) } }
    with_impact_approval do
      stub_const(AssumptionChangeAnalysis, :MAX_INPUT_BYTES, size) { assert_no_difference("AssumptionImpact.count") { assert_raises(CorpusIntake::Invalid) { request_impact } } }
    end
    @after = import_impact_document("界" * 90_000)
    @before = import_impact_document("語" * 90_000)
    assert_raises(CorpusIntake::Invalid) { impact_preview(before_snapshot_id: @after.id, after_snapshot_id: @before.id) }
  end

  test "SQL byte preflight does not mistake expanded JSONB numbers for transmitted bytes" do
    @scenario.revise!(membership: @membership, base_version_id: @version.id,
      attributes: { known_facts: (1..400).to_h { |id| [ "fact_#{id}", 1e100 ] } })
    @version_ids = @scenarios.map { |scenario| scenario.reload.current_version_id }.sort
    input = impact_preview
    wire_size = JSON.generate(AssumptionChangeAnalysis.wire_input(input)).bytesize
    stub_const(AssumptionChangeAnalysis, :MAX_INPUT_BYTES, wire_size) { assert_equal input, impact_preview }
  end

  test "fixed ID count is explicit and rejects partial casting duplicates and over-budget selection" do
    assert_equal [ 2, 9 ], AssumptionChangeAnalysis.ids("9, 2")
    assert_equal (1..50).to_a, AssumptionChangeAnalysis.ids((1..50).to_a)
    [ (1..51).to_a, [], "2 2", "1.0", "1e2", "0", "-1", "1x", { id: 1 }, [ 2**63 ] ].each do |value|
      assert_raises(CorpusIntake::Invalid) { AssumptionChangeAnalysis.ids(value) }
    end
  end

  test "digest survives JSONB object ordering but not nested numeric type or array order changes" do
    first = { "facts" => { "z" => [ 0.0, 1 ], "a" => { "y" => false, "x" => nil } } }
    reordered = { "facts" => { "a" => { "x" => nil, "y" => false }, "z" => [ 0.0, 1 ] } }
    assert_equal AssumptionChangeAnalysis.digest(first), AssumptionChangeAnalysis.digest(reordered)
    assert_not_equal AssumptionChangeAnalysis.digest(first), AssumptionChangeAnalysis.digest(first.deep_merge("facts" => { "z" => [ 0, 1 ] }))
    assert_not_equal AssumptionChangeAnalysis.digest(first), AssumptionChangeAnalysis.digest(first.deep_merge("facts" => { "z" => [ 1, 0.0 ] }))
  end

  private
    def stub_const(klass, name, value)
      original = klass.const_get(name)
      klass.send(:remove_const, name)
      klass.const_set(name, value)
      yield
    ensure
      klass.send(:remove_const, name)
      klass.const_set(name, original)
    end
end
