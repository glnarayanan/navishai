require "test_helper"
require "stringio"
require_relative "../test_helpers/scenario_test_helper"

class PrivateLoggingTest < ActionDispatch::IntegrationTest
  include ScenarioTestHelper

  test "a real taxonomy request filters private root fields while retaining the reviewed label" do
    build_scenarios
    sign_in_as users(:owner)
    previous_logger = Rails.logger
    previous_controller_logger = ActionController::Base.logger
    buffer = StringIO.new
    Rails.logger = ActiveSupport::Logger.new(buffer, level: Logger::DEBUG)
    ActionController::Base.logger = Rails.logger
    private_values = %w[name external_id title requirements follow_ups mutation proposed_label signals input result target_input decisions].index_with { |field| "private68-request-#{field}" }
    private_values["label"] = "private68-request-label"
    cluster_id = @scenario.cluster_member.issue_cluster_id
    patch workspace_corpus_corpus_analysis_path(@workspace, @corpus, @analysis), params: private_values.merge(cluster_id:, sample_count: 7)
    assert_redirected_to workspace_corpus_corpus_analysis_path(@workspace, @corpus, @analysis)
    private_values.each_key { |field| assert_equal "[FILTERED]", request.filtered_parameters.fetch(field), field }
    assert_equal "7", request.filtered_parameters.fetch("sample_count")
    assert_equal "private68-request-label", @analysis.latest_taxonomy.labels.fetch(cluster_id.to_s)
    assert_includes buffer.string, "Parameters:"
    assert_not_includes buffer.string, "private68-request-"
  ensure
    Rails.logger = previous_logger
    ActionController::Base.logger = previous_controller_logger
  end

  test "native definition writes retain expert content without disclosing it in DEBUG binds" do
    build_scenarios
    previous_logger = ActiveRecord::Base.logger
    buffer = StringIO.new
    ActiveRecord::Base.logger = ActiveSupport::Logger.new(buffer, level: Logger::DEBUG)
    requirements = ScenarioVersion::REQUIREMENT_TYPES.index_with { [] }.merge("outcomes" => [ "private68-requirement" ])
    follow_ups = [ { "after_assistant_contains" => "private68-condition", "message" => "private68-follow-up" } ]
    version = @scenario.revise!(membership: @membership, base_version_id: @scenario.current_version_id,
      attributes: { title: "private68-title", known_facts: { "plan" => "enterprise" }, requirements:, follow_ups: })
    @scenario.review!(membership: @membership, version_id: version.id, decision: "approve")
    variant = @scenario.variant!(membership: @membership, version_id: version.id, variable: "plan", after: "private68-plan",
      reason: "private68-reason", expected_difference: "private68-behaviour")
    taxonomy = TaxonomyVersion.review!(analysis: @analysis, membership: @membership, cluster_id: @scenario.cluster_member.issue_cluster_id, label: "private68-taxonomy")
    assert_equal "private68-title", version.reload.title
    assert_equal({ "plan" => "enterprise" }, version.known_facts)
    assert_equal requirements, version.requirements
    assert_equal follow_ups, version.follow_ups
    assert_equal "private68-behaviour", variant.current_version.reload.mutation.fetch("expected_difference")
    assert_equal "private68-taxonomy", taxonomy.reload.labels.fetch(@scenario.cluster_member.issue_cluster_id.to_s)
    %w[title requirements follow_ups mutation labels].each do |field|
      assert_includes buffer.string, "[\"#{field}\", \"[FILTERED]\"]"
    end
    assert_not_includes buffer.string, "private68-"
    assert_includes buffer.string, '["origin", "variant"]'
  ensure
    ActiveRecord::Base.logger = previous_logger
  end

  test "source intake and record lookup keep private identities out of native DEBUG binds" do
    membership = memberships(:owner_support)
    corpus = membership.workspace.corpora.create!(name: "Private source log proof")
    previous_logger = ActiveRecord::Base.logger
    buffer = StringIO.new
    ActiveRecord::Base.logger = ActiveSupport::Logger.new(buffer, level: Logger::DEBUG)
    snapshot = CorpusIntake.call(corpus:, membership:, name: "private71-source-name", kind: "conversations",
      bytes: JSON.generate([ { id: "private71-record-id", title: "private71-title", content: "private71-body" } ]))
    assert_equal "private71-source-name", snapshot.source.reload.name
    item = snapshot.corpus_items.find_by!(external_id: "private71-record-id")
    assert_equal "private71-record-id", item.external_id
    assert_equal "private71-body", item.content
    assert_includes buffer.string, '["name", "[FILTERED]"]'
    assert_includes buffer.string, '["external_id", "[FILTERED]"]'
    assert_not_includes buffer.string, "private71-"
    assert_equal 1, AuditEvent.where(subject_type: "Corpus", subject_id: corpus.id, action: "corpus.imported").sole.metadata.fetch("record_count")
    assert_includes buffer.string, '["action", "corpus.imported"]'
  ensure
    ActiveRecord::Base.logger = previous_logger
  end

  test "private corpus proposal calibration and result field types filter native SQL binds and request fields" do
    previous_logger = ActiveRecord::Base.logger
    buffer = StringIO.new
    ActiveRecord::Base.logger = ActiveSupport::Logger.new(buffer, level: Logger::DEBUG)
    fields = [ [ Source, "name" ], [ CorpusItem, "external_id" ], [ CorpusItem, "title" ], [ ScenarioVersion, "requirements" ], [ ScenarioVersion, "follow_ups" ],
      [ ScenarioVersion, "mutation" ], [ IssueCluster, "proposed_label" ], [ IssueCluster, "signals" ],
      [ TaxonomyVersion, "labels" ], [ ScenarioProposal, "input" ], [ ScenarioProposalResult, "result" ],
      [ CorpusAnalysisResult, "result" ], [ CorpusDiscoveryBatch, "result" ], [ CalibrationPrediction, "result" ],
      [ ModelFailureMatching, "input" ], [ ModelFailureMatchingResult, "result" ],
      [ EvaluationRunItem, "target_input" ], [ EvaluationResult, "decisions" ] ]
    request_values = {}
    fields.each_with_index do |(model, field), index|
      assert_includes model.column_names, field
      type = model.type_for_attribute(field)
      marker = "private68-#{index}"
      value = type.type == :jsonb ? { "company_text" => marker, "nested" => [ false, 0, 0.5, nil ] } : marker
      bind = ActiveRecord::Relation::QueryAttribute.new(field, value, type)
      result = ActiveRecord::Base.connection.exec_query("SELECT $1::#{type.type == :jsonb ? 'jsonb' : 'text'} AS retained", "Private field regression", [ bind ])
      assert_equal value, result.cast_values.sole
      request_values[field] = value
    end
    public_values = { "processing_method" => "local", "attempt_number" => 2, "sample_count" => 7 }
    filtered = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters).filter(request_values.merge(public_values).merge("label" => "private68-form-label"))
    assert_equal public_values, filtered.slice(*public_values.keys)
    (request_values.keys + [ "label" ]).each { |field| assert_equal "[FILTERED]", filtered.fetch(field), field }
    fields.map(&:last).uniq.each { |field| assert_includes buffer.string, "[\"#{field}\", \"[FILTERED]\"]" }
    assert_not_includes buffer.string, "private68-"
  ensure
    ActiveRecord::Base.logger = previous_logger
  end
end
