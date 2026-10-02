require "test_helper"
require_relative "../test_helpers/scenario_proposal_test_helper"

class ScenarioExtractorTest < ActiveSupport::TestCase
  include ScenarioProposalTestHelper
  setup { build_proposal_scenario }

  test "proposals cannot invent visible facts hidden truth or a different starting situation" do
    @version = @scenario.revise!(membership: @membership, base_version_id: @version.id,
      attributes: { known_facts: { "idp" => "Okta", "attempts" => { "count" => 0, "flags" => [ false, nil ] } } })
    response = proposal_response
    evidence = ScenarioExtractor.input(@version).fetch("company_evidence")
    assert_equal response, ScenarioExtractor.validate_response!(response, version: @version, model: response["model"], evidence:)
    [ { "known_facts" => { "idp" => "Okta", "entitled" => true } },
      { "known_facts" => { "idp" => "Entra" } },
      { "known_facts" => { "attempts" => { "count" => 0.0, "flags" => [ false, nil ] } } },
      { "hidden_facts" => { "cause" => "Expired certificate inferred as truth" } },
      { "situation" => "Customer login failed because the certificate expired." } ].each do |change|
      bad = response.merge("scenario" => response["scenario"].merge(change))
      assert_raises(SupportOutput::Invalid) { ScenarioExtractor.validate_response!(bad, version: @version, model: response["model"], evidence:) }
    end
    typed = response.merge("scenario" => response["scenario"].merge("known_facts" => { "attempts" => { "flags" => [ false, nil ], "count" => 0 } }))
    assert_equal typed, ScenarioExtractor.validate_response!(typed, version: @version, model: response["model"], evidence:)
    assert_empty @version.scenario_reviews
    assert_empty @version.target_input["knowledge"]
  end

  test "raw whitespace Unicode and total response bytes cannot bypass schema quote bounds" do
    response = proposal_response
    evidence = ScenarioExtractor.input(@version).fetch("company_evidence")
    boundary = response.merge("reason" => "雪" * 2000)
    assert_equal boundary, ScenarioExtractor.validate_response!(boundary, version: @version, model: response["model"], evidence:)
    [ "雪" * 2001, " " * 2000 + "x" ].each do |reason|
      assert_raises(SupportOutput::Invalid) { ScenarioExtractor.validate_response!(response.merge("reason" => reason), version: @version, model: response["model"], evidence:) }
    end
    bad_statement = response.deep_dup
    bad_statement["scenario"]["requirements"]["actions"][0] += " " * 2000
    assert_raises(SupportOutput::Invalid) { ScenarioExtractor.validate_response!(bad_statement, version: @version, model: response["model"], evidence:) }
    reference = response["evidence_links"].first["reference"]
    [ "x" * 2001, " " * 2000 + "x" ].each do |quote|
      bad = response.deep_dup
      bad["evidence_links"][0]["quote"] = quote
      disclosed = [ { "reference" => reference, "content" => quote + evidence.first["content"] } ]
      assert_raises(SupportOutput::Invalid) { ScenarioExtractor.validate_response!(bad, version: @version, model: response["model"], evidence: disclosed) }
    end
    bad_reference = response.deep_dup
    bad_reference["evidence_links"][0]["reference"] = []
    assert_raises(SupportOutput::Invalid) { ScenarioExtractor.validate_response!(bad_reference, version: @version, model: response["model"], evidence:) }
    wide = response.deep_dup
    wide["scenario"]["requirements"] = %w[outcomes actions forbidden escalation grounding].index_with { [ "雪" * 2000 ] * 20 }
    wide["evidence_links"] = wide["scenario"]["requirements"].flat_map do |kind, statements|
      statements.each_index.map { |index| { "kind" => kind, "index" => index, "reference" => reference, "quote" => "Request" } }
    end
    assert wide.to_json.bytesize > 102400
    assert_raises(SupportOutput::Invalid) { ScenarioExtractor.validate_response!(wide, version: @version, model: response["model"], evidence:) }
  end

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
