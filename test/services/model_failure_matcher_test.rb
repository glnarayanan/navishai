require "test_helper"
require_relative "../test_helpers/model_failure_matching_test_helper"

class ModelFailureMatcherTest < ActiveSupport::TestCase
  include ModelFailureMatchingTestHelper
  setup { build_model_matching_fixture }

  test "complete eligible definitions include a zero-overlap paraphrase but no hidden authority or other corpus" do
    assert_empty TraceScenarioMatching.call(item: @item).candidates
    foreign = @workspace.corpora.create!(name: "Unrelated lab")
    matching_version(corpus: foreign, item: CorpusIntake.call(corpus: foreign, membership: @membership, name: "Unrelated policy", kind: "document", bytes: @document.content).corpus_items.sole)
    input = ModelFailureMatcher.input(@item)
    assert_equal [ @version.id, @paraphrase.id, @negated.id ].sort, input["candidates"].pluck("scenario_version_id").sort
    assert_equal %w[follow_ups importance known_facts requirements situation taxonomy_label title], input["candidates"].find { |candidate| candidate["scenario_version_id"] == @paraphrase.id }["definition"].keys.sort
    assert_equal [ "Never resend at once." ], input["candidates"].find { |candidate| candidate["scenario_version_id"] == @paraphrase.id }["definition"]["requirements"]["forbidden"]
    %w[PRIVATE_HIDDEN_FACT PRIVATE_REVIEW_NOTE PRIVATE_IMPORTED_CORRECTION].each { |text| assert_not_includes input.to_json, text }
    assert_equal matching_response, ModelFailureMatcher.validate_response!(matching_response, input:, model: "matching-fixture-v1")
  end

  test "eligibility agrees with local rules and a new document or rejection changes the preview" do
    input = ModelFailureMatcher.input(@item)
    assert_equal ScenarioVersion.where(corpus: @corpus).select { |version| TraceScenarioMatching.eligible?(version) }.map(&:id).sort,
      input["candidates"].pluck("scenario_version_id").sort
    @negated.scenario.review!(membership: @membership, version_id: @negated.id, decision: "reject")
    CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Certificate policy", kind: "document", bytes: "New certificate policy.")
    assert_equal [ @paraphrase.id ], ModelFailureMatcher.input(@item)["candidates"].pluck("scenario_version_id")
    assert_not_equal ModelFailureMatcher.digest(input), ModelFailureMatcher.digest(ModelFailureMatcher.input(@item))
  end

  test "count refuses 21 eligible versions before instantiating definitions without sampling" do
    17.times { |i| matching_version(title: "Eligible #{i}") }
    assert_equal 20, ModelFailureMatcher.input(@item)["candidates"].size
    matching_version(title: "Twenty first")
    loaded = []
    callback = ->(_name, _start, _finish, _id, data) { loaded << data[:class_name] }
    ActiveSupport::Notifications.subscribed(callback, "instantiation.active_record") do
      error = assert_raises(Scenario::Invalid) { ModelFailureMatcher.input(@item) }
      assert_includes error.message, "no candidates were sampled or loaded"
    end
    assert_not_includes loaded, "ScenarioVersion"
    assert_not_includes loaded, "ScenarioEvidence"
  end

  test "100 complete linked excerpts pass and 101 refuse before loading their text" do
    records = Array.new(98) { |i| { id: "quota-evidence-#{i}", title: "Quota evidence #{i}", content: "Retry after cooldown." } }
    items = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Quota evidence", kind: "conversations", bytes: records.to_json).corpus_items.order(:id).to_a
    items.first(97).each do |item|
      @paraphrase.scenario_evidence.create!(workspace: @workspace, corpus: @corpus, corpus_item: item, kind: "expectation", excerpt: item.content)
    end
    input = ModelFailureMatcher.input(@item)
    assert_equal 100, input["candidates"].sum { |candidate| candidate["evidence"].size }
    @paraphrase.scenario_evidence.create!(workspace: @workspace, corpus: @corpus, corpus_item: items.last, kind: "expectation", excerpt: items.last.content)
    loaded = []
    callback = ->(_name, _start, _finish, _id, data) { loaded << data[:class_name] }
    ActiveSupport::Notifications.subscribed(callback, "instantiation.active_record") do
      error = assert_raises(Scenario::Invalid) { ModelFailureMatcher.input(@item) }
      assert_includes error.message, "at most 100 complete linked excerpts"
    end
    assert_not_includes loaded, "ScenarioVersion"
    assert_not_includes loaded, "ScenarioEvidence"
  end

  test "complete definition bytes reject before text loads and include JSON fields not just titles" do
    large = ScenarioVersion::REQUIREMENT_TYPES.index_with { Array.new(20) { "界" * 1000 } }
    @paraphrase.scenario.revise!(membership: @membership, base_version_id: @paraphrase.id, attributes: { requirements: large })
    loaded = []
    callback = ->(_name, _start, _finish, _id, data) { loaded << data[:class_name] }
    ActiveSupport::Notifications.subscribed(callback, "instantiation.active_record") do
      error = assert_raises(Scenario::Invalid) { ModelFailureMatcher.input(@item) }
      assert_includes error.message, "no candidate text was loaded or truncated"
    end
    assert_not_includes loaded, "ScenarioVersion"
    assert_not_includes loaded, "ScenarioEvidence"
  end

  test "full request boundary includes instructions settings and escaping" do
    input = { "text" => "界\"\n" }
    overhead = ModelFailureMatcher.payload(input, matching_configuration).to_json.bytesize - input["text"].to_json.bytesize + 2
    input["text"] = "a" * (256.kilobytes - overhead)
    assert_equal 256.kilobytes, ModelFailureMatcher.payload(input, matching_configuration).to_json.bytesize
    input["text"] += "a"
    assert_raises(Scenario::Invalid) { ModelFailureMatcher.payload(input, matching_configuration) }
  end

  test "invented foreign omitted duplicate crossed evidence and malformed suggestions fail atomically" do
    input = ModelFailureMatcher.input(@item)
    changes = [
      ->(response) { response["suggestions"][0]["scenario_version_id"] = @paraphrase.id.to_s },
      ->(response) { response["suggestions"][0]["scenario_version_id"] = -1 },
      ->(response) { response["suggestions"].pop },
      ->(response) { response["suggestions"][1] = response["suggestions"][0].deep_dup },
      ->(response) { response["suggestions"][0]["evidence"][1]["quote"] = "Invented private diagnosis" },
      ->(response) { response["suggestions"][0]["evidence"][1]["reference"] = "scenario-version-#{@negated.id}" },
      ->(response) { response["suggestions"][0]["evidence"][0]["reference"] = "scenario-version-#{@paraphrase.id}" },
      ->(response) { response["suggestions"][0]["reason"] = " " },
      ->(response) { response["suggestions"][0]["reason"] = "x" + " " * 2000 },
      ->(response) { response["suggestions"][0]["reason"] = "Null\0text" },
      ->(response) { response["suggestions"][0]["confidence"] = 1.0 },
      ->(response) { response["suggestions"][0]["decision"] = "approve" },
      ->(response) { response["model"] = "other-model" },
      ->(response) { response["usage"]["input_tokens"] = -1 },
      ->(response) { response["cost"] = { "currency" => "USD", "micro_units" => -1 } },
      ->(response) { response["labels"] = [] }
    ]
    changes.each do |change|
      response = matching_response.deep_dup
      change.call(response)
      assert_raises(SupportOutput::Invalid) { ModelFailureMatcher.validate_response!(response, input:, model: "matching-fixture-v1") }
    end
  end

  test "exact Unicode newline quotes use decoded evidence and cannot join unrelated fields" do
    input = ModelFailureMatcher.input(@item)
    response = matching_response
    candidate = input["candidates"].find { |entry| entry["scenario_version_id"] == @paraphrase.id }
    candidate["evidence"][0]["content"] = "Δ quota\nWait before resending."
    response["suggestions"][0]["evidence"][1] = { "reference" => candidate["evidence"][0]["reference"], "quote" => "Δ quota\nWait before resending." }
    assert_equal response, ModelFailureMatcher.validate_response!(response, input:, model: "matching-fixture-v1")
    response["suggestions"][0]["evidence"][1]["quote"] = "Δ quota Wait before resending."
    assert_raises(SupportOutput::Invalid) { ModelFailureMatcher.validate_response!(response, input:, model: "matching-fixture-v1") }
  end
end
