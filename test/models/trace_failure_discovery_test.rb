require "test_helper"
require_relative "../test_helpers/trace_failure_discovery_test_helper"

class TraceFailureDiscoveryTest < ActiveSupport::TestCase
  include TraceFailureDiscoveryTestHelper
  include ActiveJob::TestHelper
  setup { build_trace_discovery }

  test "complete frozen inputs include unreported traces documents definitions and executable checks but not labels or expert notes" do
    input = trace_discovery_input
    assert_equal @items.values.map(&:id).sort, input.fetch("traces").pluck("id")
    assert_equal [ @document.id ], input.fetch("documents").pluck("id")
    assert_equal [ @scenario.current_version_id ], input.fetch("scenario_definitions").pluck("id")
    assert_equal [ @case.id ], input.fetch("compiled_cases").pluck("id")
    assert_equal "approve", input.fetch("scenario_definitions").sole.fetch("review")
    assert_equal({ "fixture_private_expected" => "expiry" }, input.fetch("scenario_definitions").sole.dig("definition", "hidden_facts"))
    assert_equal true, input.fetch("compiled_cases").sole.fetch("eligible")
    assert_equal({ "type" => "field_collected", "value" => "expiry" }, input.fetch("compiled_cases").sole.fetch("checks").sole.fetch("definition"))
    assert_not_includes input.to_json, "Fixture expert note stays local"
    assert_not_includes input.to_json, @membership.user.email_address
    assert_equal "", input.fetch("traces").first.dig("context", "support_trace", "observed_failure")
    assert_includes input.fetch("traces").first.fetch("content"), "I replayed the destructive delete"
    assert_equal TraceFailureDiscoveryPreview.digest(input), TraceFailureDiscoveryPreview.digest(JSON.parse(input.to_json).transform_values { |value| value })
    assert_not_equal TraceFailureDiscoveryPreview.digest({ "fact" => 0 }), TraceFailureDiscoveryPreview.digest({ "fact" => 0.0 })
  end

  test "consent endpoint purpose and exact preview must all pass before any receipt or job" do
    with_corpus_approval do
      [ { disclose: false }, { input_digest: "wrong" }, { configuration: discovery_configuration.merge("bearer_token" => "forbidden") } ].each do |options|
        assert_no_difference [ "TraceFailureDiscovery.count", "AuditEvent.count" ] do
          assert_no_enqueued_jobs { assert_raises(CorpusIntake::Invalid) { request_trace_discovery(**options) } }
        end
      end
      old_digest = TraceFailureDiscoveryPreview.digest(trace_discovery_input)
      CorpusIntake.call(corpus: @corpus, membership: @membership, name: "New policy", kind: "document", bytes: "New entitlement rule.")
      assert_raises(CorpusIntake::Invalid) { request_trace_discovery(input_digest: old_digest) }
    end
    with_endpoint_approval do
      assert_no_difference "TraceFailureDiscovery.count" do
        assert_raises(EvaluationHttp::Error) { request_trace_discovery }
      end
    end
  end

  test "one native gateway call retains unreported failure family and gap proposals with complete mixed accounting and no authority" do
    calls = []
    with_trace_discovery_response(calls:) do
      discovery = request_trace_discovery
      expected_digest = discovery.input_digest
      2.times { TraceFailureDiscoveryJob.perform_now(discovery.id) }
      assert_equal "complete", discovery.reload.state
      assert_equal 1, calls.size
      sent = JSON.parse(calls.sole.body)
      assert_equal @items.values.map(&:id).sort, sent.fetch("traces").pluck("id")
      assert_equal discovery.request_key, calls.sole["Idempotency-Key"]
      assert_equal TraceFailureDiscoveryProtocol::VERSION, sent.fetch("schema")
      assert_equal expected_digest, TraceFailureDiscoveryPreview.digest(discovery.input_content)
      result = discovery.trace_failure_discovery_result.result_content
      assert_equal %w[proposed_failure no_finding abstain proposed_failure], result.fetch("trace_accounts").pluck("decision")
      assert_equal "Destructive retry safety", result.fetch("emerging_families").sole.fetch("label")
      assert_equal "No destructive-retry case in the disclosed set", result.fetch("coverage_gaps").sole.fetch("label")
      assert_nil result.fetch("cost")
      assert_equal "endpoint_reported", result.fetch("usage_and_cost")
      assert_equal 1, @corpus.scenarios.count
      assert_equal 1, @corpus.eval_cases.count
      assert_equal 0, HumanLabel.where(corpus: @corpus).count
      assert_equal 0, RegressionCase.where(corpus: @corpus).count
      assert_equal 0, TraceFailureReview.where(corpus: @corpus).count
      assert_equal 5, discovery.trace_failure_discovery_inputs.count
      assert_equal [ @scenario.current_version_id ], discovery.scenario_versions.ids
      assert_equal [ @case.id ], discovery.eval_cases.ids
      assert_empty AuditEvent.where(subject_type: "TraceFailureDiscovery", subject_id: discovery.id).pluck(:metadata).reject(&:empty?)
    end
  end

  test "strict schema rejects omission duplicate foreign references invented quotes missing member evidence and authority fields atomically" do
    mutations = [
      ->(r) { r["trace_accounts"].pop },
      ->(r) { r["trace_accounts"][1] = r["trace_accounts"].first },
      ->(r) { r["trace_accounts"].first["reference"] = "corpus-item-foreign" },
      ->(r) { r["trace_accounts"].first["evidence"].first["quote"] = "Invented output" },
      ->(r) { r["trace_accounts"].first["evidence"].shift },
      ->(r) { r["coverage_gaps"].first["members"] << "foreign" },
      ->(r) { r["emerging_families"].first["evidence"].shift },
      ->(r) { r["coverage_gaps"].first["comparison_refs"].pop },
      ->(r) { r["coverage_gaps"].first["comparison_refs"][0] = "scenario-version-foreign" },
      ->(r) { r["emerging_families"].first["evidence"].pop },
      ->(r) { r["coverage_percentage"] = 99 },
      ->(r) { r["trace_accounts"].first["confidence"] = 0.99 },
      ->(r) { r["model"] = "different" },
      ->(r) { r["reason"] = "unsafe\0text" }
    ]
    mutations.each do |mutate|
      response = trace_discovery_response.deep_dup
      mutate.call(response)
      assert_raises(SupportOutput::Invalid) { TraceFailureDiscoveryProtocol.validate!(response, input: trace_discovery_input, model: discovery_configuration.fetch("model")) }
      with_trace_discovery_response(response:) do
        discovery = request_trace_discovery
        TraceFailureDiscoveryJob.perform_now(discovery.id)
        receipt = discovery.reload.trace_failure_discovery_result.result_content
        assert_equal "error", receipt.fetch("decision")
        assert_empty receipt.fetch("trace_accounts")
        assert_empty receipt.fetch("coverage_gaps")
        assert_equal @items.values.map { |item| "corpus-item-#{item.id}" }.sort, receipt.fetch("unassessed_traces").sort
      end
    end
    assert_equal 1, @corpus.scenarios.count
  end

  test "whole-request abstention still accounts for each trace and cannot retain groups or failures" do
    response = trace_discovery_response.merge("decision" => "abstain", "emerging_families" => [], "coverage_gaps" => [])
    response["trace_accounts"] = response.fetch("trace_accounts").map { |entry| entry.merge("decision" => "abstain", "evidence" => []) }
    with_trace_discovery_response(response:) do
      discovery = request_trace_discovery
      TraceFailureDiscoveryJob.perform_now(discovery.id)
      assert_equal "abstain", discovery.reload.trace_failure_discovery_result.result_content.fetch("decision")
      assert_equal 4, discovery.trace_failure_discovery_result.result_content.fetch("trace_accounts").size
      assert_raises(CorpusIntake::Invalid) { TraceFailureReview.append!(discovery:, item: @items.fetch("unreported"), membership: @membership, decision: "accept", reason: "Cannot accept abstention") }
    end
    response.fetch("trace_accounts").first["decision"] = "no_finding"
    assert_raises(SupportOutput::Invalid) { TraceFailureDiscoveryProtocol.validate!(response, input: trace_discovery_input, model: discovery_configuration.fetch("model")) }
  end

  test "expert acceptance creates only an unapproved source-backed draft with late exact quote and never copies machine expectations" do
    with_trace_discovery_response do
      discovery = request_trace_discovery
      TraceFailureDiscoveryJob.perform_now(discovery.id)
      item = @items.fetch("unreported")
      assert_raises(Scenario::Invalid) { SupportTrace.propose!(item:, membership: @membership) }
      review = TraceFailureReview.append!(discovery:, item:, membership: @membership, decision: "accept", reason: "I inspected the replay and want a source-backed case.")
      assert_equal 1, @corpus.scenarios.count
      TraceFailureReview.append!(discovery:, item:, membership: @membership, decision: "reject", reason: "New expert evidence contradicts the proposal.")
      assert_raises(Scenario::Invalid) { SupportTrace.propose!(item:, membership: @membership, discovery_review: review) }
      review = TraceFailureReview.append!(discovery:, item:, membership: @membership, decision: "accept", reason: "I checked the complete source evidence again.")
      scenario = SupportTrace.propose!(item:, membership: @membership, discovery_review: review)
      assert_equal scenario.id, SupportTrace.propose!(item:, membership: @membership, discovery_review: review).id
      version = scenario.current_version
      assert_equal "A webhook retry deleted the same record twice.", version.situation
      assert_equal({ "event_id" => "delete-42", "attempt" => 2 }, version.known_facts)
      assert_equal ScenarioVersion::REQUIREMENT_TYPES.index_with { [] }, version.requirements
      assert_equal "I replayed the destructive delete and closed the issue.", version.scenario_evidence.sole.excerpt
      assert_operator item.content.index(version.scenario_evidence.sole.excerpt), :>, 4000
      assert_nil version.latest_review
      assert_not version.approved?
      assert_not_includes version.attributes.to_json, "Possible false closure"
      assert_raises(Scenario::Invalid) { scenario.review!(membership: @membership, version_id: version.id, decision: "approve") }
      assert_equal %w[accept reject accept], discovery.trace_failure_reviews.order(:id).pluck(:decision)
    end
  end

  test "changed documents definitions review or compilation block processing and expired evidence blocks review" do
    with_trace_discovery_response do
      discovery = request_trace_discovery
      @scenario.review!(membership: @membership, version_id: @scenario.current_version_id, decision: "reject", note: "Changed review")
      calls = []
      with_trace_discovery_response(calls:) { TraceFailureDiscoveryJob.perform_now(discovery.id) }
      assert_empty calls
      assert_equal "interrupted", discovery.reload.state
      assert_nil discovery.trace_failure_discovery_result
      @scenario.review!(membership: @membership, version_id: @scenario.current_version_id, decision: "approve")
      second = request_trace_discovery
      CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Company playbook", kind: "document", bytes: "Changed troubleshooting policy.")
      TraceFailureDiscoveryJob.perform_now(second.id)
      assert_equal "interrupted", second.reload.state
      assert_nil second.trace_failure_discovery_result
    end
  end

  test "new trace intake preserves fixed complete historical traces without sending the later export" do
    calls = []
    with_trace_discovery_response(calls:) do
      discovery = request_trace_discovery
      replacement = @trace_records.first.deep_dup.merge("id" => "new-export", "title" => "New unreviewed output")
      CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Production traces", kind: "traces", bytes: [ replacement ].to_json)
      TraceFailureDiscoveryJob.perform_now(discovery.id)
      assert_equal "complete", discovery.reload.state
      assert_equal @items.values.map(&:id).sort, JSON.parse(calls.sole.body).fetch("traces").pluck("id")
      assert_not_includes calls.sole.body, "new-export"
    end
  end

  test "tenant SQL lineage and immutable definition receipts inputs reviews and terminal state resist bypass" do
    with_trace_discovery_response do
      discovery = request_trace_discovery
      TraceFailureDiscoveryJob.perform_now(discovery.id)
      review = TraceFailureReview.append!(discovery:, item: @items.fetch("unreported"), membership: @membership, decision: "uncertain", reason: "Needs current engineer review.")
      [ [ TraceFailureDiscovery, discovery.id, { input_content: {} } ], [ TraceFailureDiscovery, discovery.id, { state: "queued" } ],
        [ TraceFailureDiscoveryResult, discovery.trace_failure_discovery_result.id, { result_content: {} } ],
        [ TraceFailureDiscoveryInput, discovery.trace_failure_discovery_inputs.first.id, { corpus_item_id: @document.id } ],
        [ TraceFailureDiscoveryVersion, discovery.trace_failure_discovery_versions.sole.id, { scenario_version_id: 0 } ],
        [ TraceFailureDiscoveryCase, discovery.trace_failure_discovery_cases.sole.id, { eval_case_id: 0 } ],
        [ TraceFailureReview, review.id, { decision: "accept" } ] ].each do |model, id, attributes|
        assert_raises(ActiveRecord::StatementInvalid) { model.transaction(requires_new: true) { model.where(id:).update_all(attributes) } }
      end
      foreign = workspaces(:beta_support).corpora.create!(name: "Foreign corpus")
      item = CorpusIntake.call(corpus: foreign, membership: memberships(:outsider_beta), name: "Foreign policy", kind: "document", bytes: "Foreign private evidence").corpus_items.sole
      assert_raises(ActiveRecord::InvalidForeignKey) do
        TraceFailureDiscoveryInput.transaction(requires_new: true) { discovery.trace_failure_discovery_inputs.create!(workspace: @workspace, corpus: @corpus, corpus_item: item) }
      end
      unclaimed = request_trace_discovery
      assert_raises(ActiveRecord::InvalidForeignKey) do
        TraceFailureDiscoveryResult.transaction(requires_new: true) { TraceFailureDiscoveryResult.create!(workspace: foreign.workspace, corpus: foreign, trace_failure_discovery: unclaimed, result_content: { "decision" => "error" }, created_at: Time.current) }
      end
      assert_raises(ActiveRecord::StatementInvalid) do
        TraceFailureDiscoveryResult.transaction(requires_new: true) { unclaimed.create_trace_failure_discovery_result!(workspace: @workspace, corpus: @corpus, result_content: { "decision" => nil }, created_at: Time.current) }
      end
      assert_raises(ActiveRecord::InvalidForeignKey) do
        TraceFailureDiscoveryVersion.transaction(requires_new: true) { unclaimed.trace_failure_discovery_versions.create!(workspace: foreign.workspace, corpus: foreign, scenario_version: @scenario.scenario_versions.order(:id).first) }
      end
      later_case = @corpus.eval_cases.create!(@case.attributes.except("id").merge("number" => 2, "definition_digest" => "later-synthetic-compilation"))
      assert_raises(ActiveRecord::InvalidForeignKey) do
        TraceFailureDiscoveryCase.transaction(requires_new: true) { unclaimed.trace_failure_discovery_cases.create!(workspace: foreign.workspace, corpus: foreign, eval_case: later_case) }
      end
    end
  end

  test "source expiry hides authority and retention purge removes all disclosed copies leaving content-free audit" do
    with_trace_discovery_response do
      discovery = request_trace_discovery
      TraceFailureDiscoveryJob.perform_now(discovery.id)
      review = TraceFailureReview.append!(discovery:, item: @items.fetch("unreported"), membership: @membership, decision: "accept", reason: "Fixture review")
      @document.source_snapshot.source.update!(expires_at: 1.second.ago)
      assert discovery.expired?
      assert_raises(CorpusIntake::Invalid) { TraceFailureReview.append!(discovery:, item: @items.fetch("unreported"), membership: @membership, decision: "accept", reason: "Expired") }
      assert_raises(Scenario::Invalid) { SupportTrace.propose!(item: review.corpus_item, membership: @membership, discovery_review: review) }
      SourcePurge.call(source: @document.source_snapshot.source)
      assert_not TraceFailureDiscovery.exists?(discovery.id)
      assert_not TraceFailureReview.exists?(review.id)
      assert_empty TraceFailureDiscoveryResult.where(corpus: @corpus)
      assert_empty TraceFailureDiscoveryInput.where(corpus: @corpus)
      assert_empty TraceFailureDiscoveryVersion.where(corpus: @corpus)
      assert_empty TraceFailureDiscoveryCase.where(corpus: @corpus)
      assert AuditEvent.exists?(action: "trace.discovery_completed", subject_id: discovery.id)
      assert_empty AuditEvent.where(subject_id: discovery.id, subject_type: "TraceFailureDiscovery").pluck(:metadata).reject(&:empty?)
    end
  end

  test "direct deletion of linked item version or compiled case purges the whole immutable disclosure not just one join" do
    with_corpus_approval do
      discovery = request_trace_discovery
      @case.delete
      assert_not TraceFailureDiscovery.exists?(discovery.id)
      @corpus.eval_cases.reload
      discovery = request_trace_discovery
      @scenario.current_version.delete
      assert_not TraceFailureDiscovery.exists?(discovery.id)
      discovery = request_trace_discovery
      @items.fetch("unreported").delete
      assert_not TraceFailureDiscovery.exists?(discovery.id)
    end
  end

  test "native runtime DML and sequence grants permit discovery review and purge but cannot disable its guards" do
    connection = ApplicationRecord.connection
    skip "Disposable runtime proof needs a local PostgreSQL superuser; never elevate an application role." unless connection.select_value("SELECT rolsuper FROM pg_roles WHERE rolname = current_user")
    role = connection.quote_column_name("trace_discovery_proof_#{Process.pid}")
    # The fixture transaction rolls back this disposable role and its grants.
    # These are the existing db:grant_runtime table/sequence privileges, not DDL.
    connection.execute("CREATE ROLE #{role} NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS")
    connection.execute("GRANT USAGE ON SCHEMA public TO #{role}")
    connection.execute("GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO #{role}")
    connection.execute("GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO #{role}")
    connection.execute("SET LOCAL ROLE #{role}")
    with_trace_discovery_response do
      discovery = request_trace_discovery
      TraceFailureDiscoveryJob.perform_now(discovery.id)
      review = TraceFailureReview.append!(discovery:, item: @items.fetch("unreported"), membership: @membership, decision: "accept", reason: "Restricted synthetic runtime review")
      assert_equal "complete", discovery.reload.state
      assert_equal "accept", review.decision
      %w[trace_failure_discoveries trace_failure_discovery_inputs trace_failure_discovery_versions trace_failure_discovery_cases trace_failure_discovery_results trace_failure_reviews].each do |table|
        error = assert_raises(ActiveRecord::StatementInvalid) do
          ApplicationRecord.transaction(requires_new: true) { connection.execute("ALTER TABLE #{table} DISABLE TRIGGER ALL") }
        end
        assert_kind_of PG::InsufficientPrivilege, error.cause
      end
      SourcePurge.call(source: @document.source_snapshot.source, membership: @membership)
      assert_not TraceFailureDiscovery.exists?(discovery.id)
      assert_not TraceFailureReview.exists?(review.id)
    end
  ensure
    connection&.execute("SET LOCAL ROLE NONE")
  end

  test "actual DEBUG inserts and object inspection hide input result settings and expert reason" do
    log = StringIO.new
    previous = ActiveRecord::Base.logger
    ActiveRecord::Base.logger = ActiveSupport::Logger.new(log)
    with_trace_discovery_response do
      discovery = request_trace_discovery
      TraceFailureDiscoveryJob.perform_now(discovery.id)
      TraceFailureReview.append!(discovery:, item: @items.fetch("unreported"), membership: @membership, decision: "accept", reason: "Private synthetic review marker")
      assert_includes log.string, "INSERT INTO"
      assert_includes log.string, "[FILTERED]"
      [ "I replayed the destructive delete", "Possible false closure", "Private synthetic review marker", discovery_configuration.fetch("model"), "fixture_private_expected" ].each do |private_text|
        assert_not log.string.include?(private_text), "A private discovery field leaked into SQL bind logs."
      end
      assert_not discovery.inspect.include?("I replayed the destructive delete")
      assert_not discovery.trace_failure_discovery_result.inspect.include?("Possible false closure")
    end
  ensure
    ActiveRecord::Base.logger = previous
  end
end
