require "test_helper"
require_relative "../test_helpers/trace_failure_discovery_test_helper"

class TraceFailureDiscoveryPreviewTest < ActiveSupport::TestCase
  include TraceFailureDiscoveryTestHelper
  include ActiveSupport::Testing::ConstantStubbing
  setup { build_trace_discovery }

  test "real 50 and 51 trace boundary includes late unreported input and refuses before full reads" do
    records = 50.times.map { |index| @trace_records[1].deep_dup.merge("id" => "bounded-#{index}", "title" => "Bounded trace #{index}") }
    records.last["output"]["messages"].sole["content"] = "Last complete record é diagnostic."
    CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Production traces", kind: "traces", bytes: records.to_json)
    input = trace_discovery_input
    assert_equal 50, input.fetch("traces").size
    assert_includes input.fetch("traces").last.fetch("content"), "Last complete record é diagnostic."
    records << records.first.deep_dup.merge("id" => "overflow")
    CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Production traces", kind: "traces", bytes: records.to_json)
    assert_preflight_refusal(/1–50 complete traces/)
  end

  test "real document and scenario definition count boundaries never omit late records" do
    49.times { |index| CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Policy #{index}", kind: "document", bytes: "Company policy #{index}.") }
    assert_equal 50, trace_discovery_input.fetch("documents").size
    extra = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Overflow policy", kind: "document", bytes: "Late required rule.")
    assert_preflight_refusal(/50 documents/)
    extra.source.delete
    49.times { |index| add_version(index) }
    assert_equal 50, trace_discovery_input.fetch("scenario_definitions").size
    add_version(50)
    assert_preflight_refusal(/50 current scenario definitions/)
  end

  test "real compiled case count ceiling and evidence-link ceiling refuse before loading definitions" do
    49.times do |index|
      @corpus.eval_cases.create!(@case.attributes.except("id").merge("number" => index + 2, "definition_digest" => "fixture-#{index}"))
    end
    assert_equal 50, trace_discovery_input.fetch("compiled_cases").size
    extra = @corpus.eval_cases.create!(@case.attributes.except("id").merge("number" => 51, "definition_digest" => "fixture-overflow"))
    assert_preflight_refusal(/50 compiled cases/)
    extra.delete
    records = 199.times.map { |index| { id: "evidence-#{index}", title: "Additional evidence", content: "Exact historic evidence #{index}." } }
    history = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Linked history", kind: "conversations", bytes: records.to_json)
    history.corpus_items.order(:id).first(198).each { |item| @scenario.current_version.scenario_evidence.create!(workspace: @workspace, corpus: @corpus, corpus_item: item, kind: "expectation", excerpt: item.content) }
    assert_equal 200, trace_discovery_input.fetch("scenario_definitions").sole.fetch("evidence").size
    item = history.corpus_items.order(:id).last
    @scenario.current_version.scenario_evidence.create!(workspace: @workspace, corpus: @corpus, corpus_item: item, kind: "expectation", excerpt: item.content)
    assert_preflight_refusal(/200 evidence/)
  end

  test "UTF-8 encoded byte boundary is exact and SQL bytes refuse oversized complete data before loading" do
    input = trace_discovery_input
    bytes = input.to_json.bytesize
    stub_const(TraceFailureDiscoveryPreview, :MAX_BYTES, bytes) { assert_equal input, trace_discovery_input }
    stub_const(TraceFailureDiscoveryPreview, :MAX_BYTES, bytes - 1) do
      error = assert_raises(CorpusIntake::Invalid) { trace_discovery_input }
      assert_match(/Encoded complete discovery preview/, error.message)
    end
    2.times { |index| CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Large policy #{index}", kind: "document", bytes: "é" * 70.kilobytes) }
    assert_preflight_refusal(/256 KiB/)
  end

  private
    def add_version(index)
      scenario = @corpus.scenarios.create!(workspace: @workspace, corpus_item: @items.fetch("no-finding"))
      version = scenario.scenario_versions.create!(@scenario.current_version.attributes.except("id", "scenario_id", "number").merge(scenario:, number: 1, title: "Current fixture #{index}"))
      scenario.update!(current_version: version)
    end

    def assert_preflight_refusal(pattern)
      loaded = []
      observer = ->(event) { loaded << event.payload[:class_name] if %w[CorpusItem ScenarioVersion ScenarioEvidence EvalCase EvalCaseCheck].include?(event.payload[:class_name]) }
      assert_no_difference [ "TraceFailureDiscovery.count", "AuditEvent.count" ] do
        ActiveSupport::Notifications.subscribed(observer, "instantiation.active_record") do
          error = assert_raises(CorpusIntake::Invalid) { trace_discovery_input }
          assert_match pattern, error.message
        end
      end
      assert_empty loaded
    end
end
