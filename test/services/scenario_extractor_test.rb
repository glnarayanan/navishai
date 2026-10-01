require "test_helper"
require_relative "../test_helpers/scenario_proposal_test_helper"

class ScenarioExtractorTest < ActiveSupport::TestCase
  include ScenarioProposalTestHelper
  setup { build_proposal_scenario }

  test "every proposed requirement needs exactly one real fixed source quote" do
    response = proposal_response
    evidence = ScenarioExtractor.input(@version).fetch("company_evidence")
    assert_equal response, ScenarioExtractor.validate_response!(response, version: @version, model: "scenario-fixture-2026-10", evidence:)
    changes = [ nil, [], {}, response.merge("model" => "other-model"), response.merge("schema" => "other-v1"), response.merge("reason" => " "),
      response.merge("scenario" => response["scenario"].merge("title" => [ "coerced text" ])),
      response.merge("scenario" => response["scenario"].merge("requirements" => {})), response.merge("scenario" => response["scenario"].merge("known_facts" => [])),
      response.merge("evidence_links" => []), response.merge("evidence_links" => [ response["evidence_links"].first ] * 2),
      response.merge("evidence_links" => [ response["evidence_links"].first.merge("quote" => "Invented company advice"), response["evidence_links"].last ]),
      response.merge("evidence_links" => [ response["evidence_links"].first.merge("reference" => "scenario-evidence-foreign"), response["evidence_links"].last ]),
      response.merge("evidence_links" => [ response["evidence_links"].first.merge("index" => 0.0), response["evidence_links"].last ]),
      response.merge("usage" => { "input_tokens" => -1, "output_tokens" => 7 }), response.merge("cost" => { "currency" => "USD", "micro_units" => 0.5 }) ]
    changes.each do |bad|
      assert_raises(SupportOutput::Invalid, bad.inspect) { ScenarioExtractor.validate_response!(bad, version: @version, model: "scenario-fixture-2026-10", evidence:) }
    end
    abstain = response.merge("decision" => "abstain", "scenario" => nil, "evidence_links" => [])
    assert_equal abstain, ScenarioExtractor.validate_response!(abstain, version: @version, model: "scenario-fixture-2026-10", evidence:)
    assert_raises(SupportOutput::Invalid) { ScenarioExtractor.validate_response!(abstain.merge("scenario" => response["scenario"]), version: @version, model: "scenario-fixture-2026-10", evidence:) }
  end

  test "bounded evidence includes 20 but excludes 21 and measures encoded bytes" do
    19.times do |index|
      item = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Small document #{index}", kind: "document", bytes: "Evidence #{index}").corpus_items.sole
      @version.scenario_evidence.create!(workspace: @workspace, corpus: @corpus, corpus_item: item, kind: "expectation", excerpt: "Evidence #{index}")
    end
    assert_equal 20, ScenarioExtractor.input(@version)["company_evidence"].size
    @version.scenario_evidence.create!(workspace: @workspace, corpus: @corpus, corpus_item: @knowledge, kind: "knowledge", excerpt: "Request the certificate expiry date.")
    assert_raises(Scenario::Invalid) { ScenarioExtractor.input(@version) }
    # Wide UTF-8 content crosses the byte limit while remaining under text limits.
    @version = @scenarios.find { |scenario| scenario != @scenario }.current_version
    6.times do |index|
      text = "#{index}:#{'界' * 3900}"
      item = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Wide document #{index}", kind: "document", bytes: text).corpus_items.sole
      @version.scenario_evidence.create!(workspace: @workspace, corpus: @corpus, corpus_item: item, kind: "expectation", excerpt: text)
    end
    assert_raises(Scenario::Invalid) { ScenarioExtractor.input(@version) }
  end

  test "invalid replies and transport errors are scrubbed errors not support failures or source expectations" do
    with_proposal_response(response: proposal_response.merge("model" => "wrong-model")) do
      proposal = request_proposal
      assert_equal "error", ScenarioExtractor.call(proposal)["decision"]
    end
    with_scenario_approval do
      proposal = request_proposal
      with_test_method(Resolv, :getaddresses, ->(*) { [ "93.184.216.34" ] }) do
        with_test_method(EvaluationHttp, :perform, ->(*) { raise Net::ReadTimeout, "private source and credential" }) do
          result = ScenarioExtractor.call(proposal)
          assert_equal "error", result["decision"]
          assert_not_includes result.to_json, "private source and credential"
          assert_includes result["reason"], "unknown"
        end
      end
    end
  end
end
