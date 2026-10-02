require_relative "evaluation_test_helper"

module RecordedEvaluationTestHelper
  include EvaluationTestHelper

  def build_recorded_evaluation
    @membership = memberships(:owner_support)
    @workspace = @membership.workspace
    @corpus = @workspace.corpora.create!(name: "Production regression fixture")
    @knowledge = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Certificate policy", kind: "document",
      bytes: "Request the certificate expiry date before suggesting configuration changes. Never claim a change without a confirmed action.").corpus_items.sole
    @trace = JSON.parse(File.read(Rails.root.join("test/fixtures/files/production_traces.json"))).sole
    @snapshot = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Recorded failure fixture", kind: "traces", bytes: [ @trace ].to_json)
    @trace_item = @snapshot.corpus_items.sole
    @scenario = SupportTrace.propose!(item: @trace_item, membership: @membership)
    requirements = ScenarioVersion::REQUIREMENT_TYPES.index_with { [] }.merge(
      "outcomes" => [ "Do not claim an unconfirmed configuration change." ], "actions" => [ "Request the certificate expiry date." ])
    @scenario.revise!(membership: @membership, base_version_id: @scenario.current_version_id,
      attributes: { requirements:, taxonomy_label: "Company SAML diagnostics", importance: "high", hidden_facts: { actual_cause: "private expired certificate" } },
      evidence_item_id: @knowledge.id, evidence_kind: "expectation", excerpt: @knowledge.content)
    @scenario.review!(membership: @membership, version_id: @scenario.current_version_id, decision: "approve", note: "Fixture expert checked current company policy.")
    @action_grader = Grader.define!(corpus: @corpus, membership: @membership, name: "Collect expiry", kind: "deterministic", definition: { "type" => "tool_called", "value" => "collect_expiry" })
    @outcome_grader = Grader.define!(corpus: @corpus, membership: @membership, name: "No false change claim", kind: "deterministic", definition: { "type" => "text_absent", "value" => "I changed" })
    evidence = @scenario.current_version.scenario_evidence.find_by!(corpus_item: @knowledge)
    @checks = requirements.flat_map do |kind, statements|
      statements.each_index.map { |index| { "requirement_kind" => kind, "requirement_index" => index, "grader_version_id" => (kind == "actions" ? @action_grader : @outcome_grader).current_version_id, "scenario_evidence_id" => evidence.id } }
    end
    @case = compile_case
    @suite = @corpus.eval_suites.create!(workspace: @workspace, name: "Production replay readiness")
    @suite.add_case!(membership: @membership, case_id: @case.id)
    @target = EvaluationTarget.define!(corpus: @corpus, membership: @membership, name: "Recorded SSO failure", adapter: "recorded", configuration: {}, trace_item_id: @trace_item.id)
  end

  def compile_replay_history(situations:)
    situations.map.with_index do |situation, index|
      @scenario.revise!(membership: @membership, base_version_id: @scenario.current_version_id,
        attributes: { title: "Replay fixture case #{index + 1}", situation: })
      @scenario.review!(membership: @membership, version_id: @scenario.current_version_id, decision: "approve", note: "Synthetic replay history, not pilot judgments.")
      evidence = @scenario.current_version.scenario_evidence.find_by!(corpus_item: @knowledge, kind: "expectation")
      compile_case(checks: @checks.map { |check| check.merge("scenario_evidence_id" => evidence.id) })
    end
  end

  def build_compared_evaluation
    build_recorded_evaluation
    @before = request_run
    EvaluationRunJob.perform_now(@before.id)
    @target.revise!(membership: @membership, version_id: @target.current_version_id, adapter: "scripted",
      configuration: script_configuration(output: support_output(tools: [ "collect_expiry" ])))
    @after = request_run
    EvaluationRunJob.perform_now(@after.id)
  end
end
