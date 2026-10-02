require "test_helper"
require_relative "../test_helpers/evaluation_test_helper"
require_relative "../test_helpers/http_target_test_helper"
require_relative "../test_helpers/model_discovery_test_helper"

class SupportLabAcceptanceTest < ActiveSupport::TestCase
  include EvaluationTestHelper
  include HttpTargetTestHelper
  include ModelDiscoveryTestHelper

  test "fresh company history reaches calibrated failure and same case regression replay" do
    original_registry = ENV["NAVISHAI_EVALUATION_ENDPOINTS"]
    @membership = memberships(:owner_support)
    @workspace = @membership.workspace
    @corpus = @workspace.corpora.create!(name: "Delivery reliability lab")
    snapshot = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Delivery history", kind: "conversations", bytes: [
      { id: "replay", title: "Flux webhook replay duplicate writes", content: "Flux webhook replay caused duplicate writes. Collect delivery IDs. Engineering escalation. Still broken.", context: { component: "delivery replay", impact: "critical" } },
      { id: "quota-1", title: "REST quota retry headers", content: "REST quota retry headers. Respect Retry-After. REST quota retry timing." },
      { id: "quota-2", title: "REST quota retry timing", content: "REST quota retry timing. Respect Retry-After. REST quota retry headers." }
    ].to_json)
    policy = "Collect delivery IDs. Treat duplicate writes as a data integrity risk and escalate to Engineering. Do not claim replay integrity without evidence."
    document = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Replay safety policy", kind: "document", bytes: policy).corpus_items.sole
    analysis = CorpusAnalysis.request!(corpus: @corpus, membership: @membership, scenario_limit: 2)
    CorpusAnalysisJob.perform_now(analysis.id)
    assert_equal "complete", analysis.reload.state
    assert_equal [ 3, 1, 2, 2 ], analysis.summary.values_at("conversations", "documents", "clusters", "represented_clusters")
    assert_equal (snapshot.corpus_items.ids + [ document.id ]).sort, analysis.corpus_items.ids.sort
    families = analysis.issue_clusters.map { |cluster| cluster.cluster_members.joins(:corpus_item).order("corpus_items.external_id").pluck("corpus_items.external_id") }
    assert_equal [ %w[quota-1 quota-2], [ "replay" ] ], families.sort
    cluster = analysis.issue_clusters.joins(:cluster_members).find_by!(cluster_members: { corpus_item_id: snapshot.corpus_items.find_by!(external_id: "replay").id })
    taxonomy = TaxonomyVersion.review!(analysis:, membership: @membership, cluster_id: cluster.id, label: "Webhook replay integrity")
    assert_equal "Webhook replay integrity", taxonomy.labels.fetch(cluster.id.to_s)
    scenarios = ScenarioMining.call(analysis:, membership: @membership)
    scenario = scenarios.find { |candidate| candidate.corpus_item.external_id == "replay" }
    assert_equal "Webhook replay integrity", scenario.current_version.taxonomy_label
    assert_equal "critical", scenario.current_version.importance
    assert_includes scenario.current_version.selection_reason, "ahead of volume"
    assert_not scenario.current_version.approved?
    requirements = ScenarioVersion::REQUIREMENT_TYPES.index_with { [] }.merge(
      "outcomes" => [ "Recognise the replay as an integrity risk rather than a confirmed resolution." ],
      "actions" => [ "Collect delivery IDs before assessing the replay." ], "escalation" => [ "Escalate duplicate writes to Engineering." ])
    scenario.revise!(membership: @membership, base_version_id: scenario.current_version_id,
      attributes: { situation: "A webhook replay produced duplicate writes after an offset reset.", requirements:, hidden_facts: { root_cause: "internal replay defect" } },
      evidence_item_id: document.id, evidence_kind: "expectation", excerpt: policy)
    scenario.revise!(membership: @membership, base_version_id: scenario.current_version_id, attributes: {},
      evidence_item_id: document.id, evidence_kind: "knowledge", excerpt: policy)
    scenario.review!(membership: @membership, version_id: scenario.current_version_id, decision: "approve", note: "Fixture expert checked the safety policy, not the historic closure.")
    evidence = scenario.current_version.scenario_evidence.find_by!(corpus_item: document, kind: "expectation")
    assert_equal document.source_snapshot_id, evidence.corpus_item.source_snapshot_id
    assert_not scenarios.find { |candidate| candidate != scenario }.current_version.approved?

    bad = support_output(text: "The replay completed. No engineering review is needed.", tools: [ "collect_delivery_ids" ])
    good = support_output(text: "Duplicate writes need Engineering review. Please share delivery IDs.", tools: [ "collect_delivery_ids" ]).merge("escalation" => { "triggered" => true, "team" => "Engineering" })
    missed = support_output(text: "This seems safe, but no integrity evidence is available.", tools: [ "collect_delivery_ids" ])
    ENV["NAVISHAI_EVALUATION_ENDPOINTS"] = [ HTTP_ENDPOINT, "https://eval.example.test/candidate/v1", "https://eval.example.test/candidate/v2" ].map { |endpoint| { workspace_id: @workspace.id, endpoint: } }.to_json
    judge = Grader.define!(corpus: @corpus, membership: @membership, name: "Replay risk recognition", kind: "rubric_judge", definition: {
      "rubric" => "Pass only when the response recognises the company policy's integrity risk. Fail unsupported resolution or dismissal of risk.", "confidence_threshold" => 0.8,
      "execution" => { "endpoint" => HTTP_ENDPOINT, "model" => "fixture-risk-judge", "settings" => { "temperature" => 0, "max_output_tokens" => 1024, "seed" => 11 } }
    })
    actions = Grader.define!(corpus: @corpus, membership: @membership, name: "Collect delivery evidence", kind: "deterministic", definition: { "type" => "tool_called", "value" => "collect_delivery_ids" })
    escalation = Grader.define!(corpus: @corpus, membership: @membership, name: "Engineering handoff", kind: "deterministic", definition: { "type" => "escalation", "value" => "Engineering" })
    graders = { "outcomes" => judge, "actions" => actions, "escalation" => escalation }
    checks = graders.map { |kind, grader| { "requirement_kind" => kind, "requirement_index" => 0, "grader_version_id" => grader.current_version_id, "scenario_evidence_id" => evidence.id } }
    item = EvalCompiler.call(scenario:, membership: @membership, version_id: scenario.current_version_id, checks:)
    assert_equal scenario.current_version.latest_review.id, item.scenario_review_id
    assert_equal 3, item.eval_case_checks.count
    check = item.eval_case_checks.find_by!(requirement_kind: "outcomes")
    set = CalibrationSet.define!(corpus: @corpus, membership: @membership, name: "Held-out replay labels", grader_version_id: judge.current_version_id)
    labelled = [ [ bad, "fail" ], [ good, "pass" ], [ missed, "fail" ] ].map do |output, decision|
      sample = set.add_sample!(membership: @membership, check_id: check.id, cohort: "held_out", output:)
      sample.label!(membership: @membership, previous_id: nil, decision:, rationale: "Fixture expert applied the exact replay policy.")
      sample
    end
    predictions = { bad.fetch("messages").sole.fetch("content") => "fail", good.fetch("messages").sole.fetch("content") => "pass", missed.fetch("messages").sole.fetch("content") => "pass" }
    calls = []
    endpoint = lambda do |uri, request, _address|
      payload = JSON.parse(request.body)
      calls << { path: uri.path, key: request["Idempotency-Key"], payload: }
      if payload.fetch("schema") == "support-target-v1"
        (uri.path == "/candidate/v1" ? bad : good).to_json
      else
        output_quote = payload.fetch("target_output").fetch("messages").sole.fetch("content")
        { "schema" => "support-judge-v1", "model" => "fixture-risk-judge", "decision" => predictions.fetch(output_quote),
          "reason" => "Fixture gateway judgment; one known missed failure is deliberate.", "confidence" => 0.9,
          "quotes" => [ { "reference" => "company_evidence", "quote" => policy }, { "reference" => "target_output", "quote" => output_quote } ], "usage" => nil, "cost" => nil }.to_json
      end
    end
    with_test_method(Resolv, :getaddresses, ->(*) { [ "93.184.216.34" ] }) do
      with_test_method(EvaluationHttp, :perform, endpoint) do
        labelled.each do |sample|
          attempt = CalibrationJudgeRun.request!(sample:, membership: @membership, disclose: true)
          2.times { CalibrationJudgeRunJob.perform_now(attempt.id) }
        end
        report = CalibrationReport.call(set:)
        assert_equal [ 3, 1, 1, 1, 0 ], report.values_at(:compared, :true_positive, :true_negative, :false_negative, :false_positive)
        assert_equal 0.5, report.fetch(:recall)
        assert_in_delta 1.0 / 3, report.fetch(:disagreement_rate)
        assert_equal 0, CalibrationReport.call(set:, cohort: "development").fetch(:samples)
        @suite = @corpus.eval_suites.create!(workspace: @workspace, name: "Replay readiness")
        @suite.add_case!(membership: @membership, case_id: item.id)
        target = EvaluationTarget.define!(corpus: @corpus, membership: @membership, name: "HTTP candidate", adapter: "http", configuration: { "endpoint" => "https://eval.example.test/candidate/v1" })
        first = request_run(version: target.current_version, disclose: true, judge_disclose: true)
        2.times { EvaluationRunJob.perform_now(first.id) }
        failure = first.evaluation_results.sole
        assert_equal "complete", first.reload.state
        assert_equal "fail", failure.status
        assert_equal %w[escalation outcomes], failure.decisions.select { |decision| decision["decision"] == "fail" }.map { |decision| item.eval_case_checks.find(decision.fetch("check_id")).requirement_kind }.sort
        assert_equal "pass", failure.decisions.find { |decision| decision["grader_version_id"] == actions.current_version_id }.fetch("decision")
        @regression = @corpus.eval_suites.create!(workspace: @workspace, name: "Replay regressions", kind: "regression")
        admission = failure.add_regression!(membership: @membership, suite_id: @regression.id, rationale: "Never treat duplicate writes as a completed resolution.")
        assert_equal [ failure.id, item.id, @membership.user_id ], [ admission.evaluation_result_id, admission.eval_case_id, admission.reviewed_by_id ]
        old_target = target.current_version
        target.revise!(membership: @membership, version_id: old_target.id, configuration: { "endpoint" => "https://eval.example.test/candidate/v2" })
        replay = request_run(suite: @regression, version: target.current_version, disclose: true, judge_disclose: true)
        2.times { EvaluationRunJob.perform_now(replay.id) }
        assert_equal "pass", replay.evaluation_results.sole.status
        assert_equal [ item.id ], replay.evaluation_run_items.pluck(:eval_case_id)
        assert_equal old_target.id, first.reload.evaluation_target_version_id
        assert_equal "fail", failure.reload.status
        assert_equal bad, failure.output
        assert_equal good, replay.evaluation_results.sole.output
        assert_equal 7, calls.size
        assert_equal 7, calls.map { |call| call.fetch(:key) }.uniq.size
        target_calls = calls.select { |call| call.fetch(:payload).fetch("schema") == "support-target-v1" }
        assert_equal %w[/candidate/v1 /candidate/v2], target_calls.map { |call| call.fetch(:path) }
        expected_input = { "situation" => "A webhook replay produced duplicate writes after an offset reset.",
          "known_facts" => { "component" => "delivery replay", "impact" => "critical" },
          "knowledge" => [ { "reference" => "corpus-item-#{document.id}", "content" => policy } ] }
        target_calls.each do |call|
          assert_equal expected_input, call.fetch(:payload).fetch("input")
          assert_not_includes call.fetch(:payload).to_json, requirements.fetch("outcomes").sole
        end
        assert_not_includes calls.to_json, "internal replay defect"
        CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Replay safety policy", kind: "document", bytes: policy + " Also collect replay offsets.")
        assert scenario.current_version.stale?
        assert_raises(EvalCase::Invalid) { request_run(suite: @regression, version: target.current_version, disclose: true, judge_disclose: true) }
        assert_equal "fail", failure.reload.status
        assert_equal "pass", replay.evaluation_results.sole.status
        assert_equal 7, calls.size
      end
    end
  ensure
    original_registry ? ENV["NAVISHAI_EVALUATION_ENDPOINTS"] = original_registry : ENV.delete("NAVISHAI_EVALUATION_ENDPOINTS")
  end

  test "model discovery feeds corrected expert contracts held-out calibration and the same fixed regression" do
    build_discovery_corpus
    original_registry = ENV["NAVISHAI_EVALUATION_ENDPOINTS"]
    ENV["NAVISHAI_EVALUATION_ENDPOINTS"] = [ HTTP_ENDPOINT, "https://eval.example.test/agent/v1", "https://eval.example.test/agent/v2" ].map { |endpoint| { workspace_id: @workspace.id, endpoint: } }.to_json
    bad = support_output(text: "Retries succeeded. There is no data-integrity risk.")
    good = support_output(text: "Repeated deletes pose a data-integrity risk; Engineering must investigate.").merge("escalation" => { "triggered" => true, "team" => "Engineering" })
    missed = support_output(text: "Retries seem harmless, although records are missing.")
    source_quote = "Webhook retries repeated a delete event and caused data loss."
    predictions = { bad.fetch("messages").sole.fetch("content") => "fail", good.fetch("messages").sole.fetch("content") => "pass", missed.fetch("messages").sole.fetch("content") => "pass" }
    calls = []
    endpoint = lambda do |uri, request, _address|
      payload = JSON.parse(request.body)
      calls << { payload:, key: request["Idempotency-Key"] }
      case payload.fetch("schema")
      when "support-corpus-v1" then discovery_response.to_json
      when "support-target-v1" then (uri.path == "/agent/v1" ? bad : good).to_json
      when "support-judge-v1"
        output_quote = payload.fetch("target_output").fetch("messages").sole.fetch("content")
        { "schema" => "support-judge-v1", "model" => "risk-judge-fixture", "decision" => predictions.fetch(output_quote), "reason" => "Synthetic judge deliberately misses one held-out failure.", "confidence" => 0.9,
          "quotes" => [ { "reference" => "company_evidence", "quote" => source_quote }, { "reference" => "target_output", "quote" => output_quote } ], "usage" => nil, "cost" => nil }.to_json
      end
    end
    with_corpus_approval do
      with_test_method(Resolv, :getaddresses, ->(*) { [ "93.184.216.34" ] }) do
        with_test_method(EvaluationHttp, :perform, endpoint) do
          analysis = request_model_analysis
          2.times { CorpusAnalysisJob.perform_now(analysis.id) }
          cluster = analysis.issue_clusters.find_by!(proposed_label: "Unsafe delete retries")
          TaxonomyVersion.review!(analysis:, membership: @membership, cluster_id: cluster.id, label: "Expert's destructive retries")
          scenarios = ScenarioMining.call(analysis:, membership: @membership)
          scenario = scenarios.find { |candidate| candidate.corpus_item.external_id == "rare" }
          proposal = scenario.current_version
          assert_not proposal.approved?
          assert_equal "critical", proposal.importance
          assert_equal "Expert's destructive retries", proposal.taxonomy_label
          assert_raises(EvalCase::Invalid) { EvalCompiler.call(scenario:, membership: @membership, version_id: proposal.id, checks: []) }
          assert_equal 0, HumanLabel.where(corpus: @corpus).count
          requirements = ScenarioVersion::REQUIREMENT_TYPES.index_with { [] }.merge("outcomes" => [ "Treat destructive retries as a data-integrity risk." ], "escalation" => [ "Escalate destructive retries to Engineering." ])
          scenario.revise!(membership: @membership, base_version_id: proposal.id, attributes: { requirements:, hidden_facts: { defect: "PRIVATE INTERNAL ANSWER" } })
          scenario.review!(membership: @membership, version_id: scenario.current_version_id, decision: "approve", note: "Synthetic expert separated risk recognition from the model's escalation outcome.")
          assert_equal [ "Escalate repeated destructive deletes to Engineering." ], proposal.reload.requirements["outcomes"]
          source = scenario.current_version.scenario_evidence.find_by!(corpus_item: @items.fetch("rare"))
          policy = scenario.current_version.scenario_evidence.find_by!(corpus_item: @document)
          judge = Grader.define!(corpus: @corpus, membership: @membership, name: "Retry risk recognition", kind: "rubric_judge", definition: {
            "rubric" => "Pass only when the response recognises repeated destructive deletes as a data-integrity risk. Fail unsupported dismissal of risk.", "confidence_threshold" => 0.8,
            "execution" => discovery_configuration.merge("model" => "risk-judge-fixture")
          })
          escalation = Grader.define!(corpus: @corpus, membership: @membership, name: "Destructive retry handoff", kind: "deterministic", definition: { "type" => "escalation", "value" => "Engineering" })
          item = EvalCompiler.call(scenario:, membership: @membership, version_id: scenario.current_version_id, checks: [
            { "requirement_kind" => "outcomes", "requirement_index" => 0, "grader_version_id" => judge.current_version_id, "scenario_evidence_id" => source.id },
            { "requirement_kind" => "escalation", "requirement_index" => 0, "grader_version_id" => escalation.current_version_id, "scenario_evidence_id" => policy.id }
          ])
          set = CalibrationSet.define!(corpus: @corpus, membership: @membership, name: "Held-out destructive retry labels", grader_version_id: judge.current_version_id)
          [ [ bad, "fail" ], [ good, "pass" ], [ missed, "fail" ] ].each do |output, decision|
            sample = set.add_sample!(membership: @membership, check_id: item.eval_case_checks.find_by!(requirement_kind: "outcomes").id, cohort: "held_out", output:)
            sample.label!(membership: @membership, previous_id: nil, decision:, rationale: "Synthetic expert applied the exact destructive retry evidence.")
            attempt = CalibrationJudgeRun.request!(sample:, membership: @membership, disclose: true)
            2.times { CalibrationJudgeRunJob.perform_now(attempt.id) }
          end
          report = CalibrationReport.call(set:)
          assert_equal [ 3, 1, 1, 1, 0 ], report.values_at(:compared, :true_positive, :true_negative, :false_negative, :false_positive)
          assert_equal 0.5, report[:recall]
          assert_equal %w[fail fail pass], set.calibration_samples.flat_map { |sample| sample.latest_labels.pluck(:decision) }.sort
          @suite = @corpus.eval_suites.create!(workspace: @workspace, name: "Destructive retry readiness")
          @suite.add_case!(membership: @membership, case_id: item.id)
          target = EvaluationTarget.define!(corpus: @corpus, membership: @membership, name: "Retry HTTP fixture", adapter: "http", configuration: { "endpoint" => "https://eval.example.test/agent/v1" })
          first = request_run(version: target.current_version, disclose: true, judge_disclose: true)
          2.times { EvaluationRunJob.perform_now(first.id) }
          failure = first.evaluation_results.sole
          assert_equal "fail", failure.status
          assert_equal %w[fail fail], failure.decisions.pluck("decision")
          regression = @corpus.eval_suites.create!(workspace: @workspace, name: "Destructive retry regressions", kind: "regression")
          admission = failure.add_regression!(membership: @membership, suite_id: regression.id, rationale: "Synthetic expert retains the missed risk and handoff on this fixed case.")
          assert_equal [ failure.id, item.id, @membership.user_id ], [ admission.evaluation_result_id, admission.eval_case_id, admission.reviewed_by_id ]
          target.revise!(membership: @membership, version_id: target.current_version_id, configuration: { "endpoint" => "https://eval.example.test/agent/v2" })
          replay = request_run(suite: regression, version: target.current_version, disclose: true, judge_disclose: true)
          2.times { EvaluationRunJob.perform_now(replay.id) }
          assert_equal "pass", replay.evaluation_results.sole.status
          assert_equal [ item.id ], replay.evaluation_run_items.pluck(:eval_case_id)
          assert_equal "fail", failure.reload.status
          assert_equal 8, calls.size
          assert_equal 8, calls.pluck(:key).uniq.size
          assert_equal({ "support-corpus-v1" => 1, "support-judge-v1" => 5, "support-target-v1" => 2 }, calls.map { |call| call.dig(:payload, "schema") }.tally)
          target_calls = calls.select { |call| call.dig(:payload, "schema") == "support-target-v1" }
          target_calls.each { |call| assert_equal({ "situation" => "A webhook retry repeats a delete while the customer remains blocked.", "known_facts" => {}, "knowledge" => [] }, call.dig(:payload, "input")) }
          assert_not_includes calls.to_json, "PRIVATE INTERNAL ANSWER"
          assert_not_includes target_calls.to_json, "Treat destructive retries as a data-integrity risk."
          assert_equal discovery_response, analysis.reload.corpus_analysis_result.result.except("elapsed_ms", "usage_and_cost")
          assert_not scenarios.find { |candidate| candidate != scenario }.current_version.approved?
        end
      end
    end
  ensure
    original_registry ? ENV["NAVISHAI_EVALUATION_ENDPOINTS"] = original_registry : ENV.delete("NAVISHAI_EVALUATION_ENDPOINTS")
  end
end
