# Synthetic operations evidence shared by recovery, upgrade and native-job proofs.
require Rails.root.join("test/test_helpers/model_failure_matching_test_helper")
require Rails.root.join("test/test_helpers/assumption_impact_test_helper")
require Rails.root.join("test/test_helpers/trace_failure_discovery_test_helper")
require Rails.root.join("test/test_helpers/batch_discovery_test_helper")

module Operations
  module CurrentWorkflowsProof
    MODELS = [ ModelFailureMatching, ModelFailureMatchingCandidate, ModelFailureMatchingResult,
      AssumptionImpact, AssumptionImpactInput, AssumptionImpactResult,
      TraceFailureDiscovery, TraceFailureDiscoveryInput, TraceFailureDiscoveryVersion,
      TraceFailureDiscoveryCase, TraceFailureDiscoveryResult, TraceFailureReview ].freeze

    def self.fixture(helper, membership)
      Object.new.extend(helper).tap do |fixture|
        fixture.define_singleton_method(:memberships) { |name| membership || Membership.find(ActiveRecord::FixtureSet.identify(name)) }
        fixture.define_singleton_method(:workspaces) { |name| membership&.workspace || Workspace.find(ActiveRecord::FixtureSet.identify(name)) }
      end
    end
    private_class_method :fixture

    def self.seed(execute: true, membership: nil)
      matching = fixture(ModelFailureMatchingTestHelper, membership)
      matching.build_model_matching_fixture
      match = nil
      matching.with_matching_response do
        match = matching.request_matching
        ModelFailureMatchingJob.perform_now(match.id) if execute
      end
      impact = fixture(AssumptionImpactTestHelper, membership)
      impact.build_change_impact
      change = nil
      impact.with_impact_response do
        change = impact.request_impact
        AssumptionImpactJob.perform_now(change.id) if execute
      end
      discovery = fixture(TraceFailureDiscoveryTestHelper, membership)
      discovery.build_trace_discovery
      found = nil
      discovery.with_trace_discovery_response do
        found = discovery.request_trace_discovery
        TraceFailureDiscoveryJob.perform_now(found.id) if execute
      end
      requests = [ match, change, found ]
      manifest = { "requests" => requests.to_h { |request| [ request.class.name, request.id ] } }
      return manifest unless execute

      raise "Current workflows did not complete" unless requests.all? { |request| request.reload.state == "complete" }
      raise "Matching result" unless match.model_failure_matching_result.result.fetch("suggestions").pluck("decision") == %w[match no_match uncertain]
      raise "Impact result" unless change.assumption_impact_result.result.fetch("affected").sole.fetch("after_quote") == "Business and Enterprise plans support SAML."
      raise "Trace accounting" unless found.trace_failure_discovery_result.result_content.fetch("trace_accounts").pluck("decision") == %w[proposed_failure no_finding abstain proposed_failure]
      review = TraceFailureReview.append!(discovery: found, item: discovery.instance_variable_get(:@items).fetch("unreported"),
        membership: discovery.instance_variable_get(:@membership), decision: "accept", reason: "Synthetic expert: inspect destructive replay.")
      draft = SupportTrace.propose!(item: review.corpus_item, membership: discovery.instance_variable_get(:@membership), discovery_review: review)
      raise "Trace draft inherited authority" unless draft.current_version.requirements.values.all?(&:empty?) && !draft.current_version.approved?

      parent = impact.instance_variable_get(:@scenario)
      variant = parent.variant!(membership: impact.instance_variable_get(:@membership), version_id: parent.current_version_id,
        changes: { "plan" => "enterprise", "retries" => 1 }, reason: "Synthetic coupled account change.", expected_difference: "Expert must define the changed entitlement behaviour.")
      raise "Variant inherited expectations" unless variant.current_version.requirements.values.all?(&:empty?) && variant.current_version.hidden_facts.empty? && variant.current_version.follow_ups.empty?
      mined = parent.scenario_versions.order(:id).first
      raise "Local source review notes" unless mined.draft_notes.fetch("method") == "literal-source-review-v2" && mined.known_facts.empty?

      observations = fixture(BatchDiscoveryTestHelper, membership)
      observations.build_batch_corpus
      batch = nil
      observations.with_batch_responses do
        batch = observations.request_batch_analysis(processing_method: "model_batch_observations")
        CorpusAnalysisJob.perform_now(batch.id)
      end
      raise "V2 observation retention" unless batch.reload.state == "complete" && batch.processing_method == BatchCorpusDiscovery::OBSERVATIONS_VERSION &&
        batch.corpus_analysis_result.result.fetch("observations").size == 2 && batch.corpus_analysis_result.result.fetch("observations").all? { |entry| entry.fetch("evidence").size == 2 }
      large = CorpusAnalysis.request!(corpus: parent.corpus, membership: impact.instance_variable_get(:@membership),
        scenario_limit: 2, processing_method: "local_large_full_text")
      CorpusAnalysisJob.perform_now(large.id)
      raise "Complete-text processing version" unless large.reload.state == "complete" && large.processing_method == CorpusAnalysis::LARGE_FULL_TEXT_METHOD && large.corpus_analysis_inputs.count == parent.corpus.current_items.count

      records = MODELS.to_h do |model|
        relation = if model == TraceFailureReview
          model.where(trace_failure_discovery: found)
        elsif model.table_name.start_with?("model_failure_matching")
          model.where(corpus: match.corpus)
        elsif model.table_name.start_with?("assumption_impact")
          model.where(corpus: change.corpus)
        else
          model.where(corpus: found.corpus)
        end
        [ model.name, relation.order(:id).to_a ]
      end
      records["ScenarioVersion"] = [ mined, variant.current_version, draft.current_version ]
      records["Scenario"] = [ variant ]
      records["CorpusAnalysis"] = [ batch, large ]
      records["CorpusAnalysisResult"] = [ batch.corpus_analysis_result, large.corpus_analysis_result ].compact
      records["CorpusDiscoveryBatch"] = batch.corpus_discovery_batches.order(:id).to_a
      manifest.merge("records" => records.transform_values { |rows| rows.map { |row| { "id" => row.id, "digest" => fingerprint(row.reload) } } },
        "sources" => [ match.corpus, change.corpus, found.corpus, batch.corpus ].map { |corpus| corpus.sources.order(:id).first.id },
        "variant" => variant.id, "parent_version" => parent.current_version_id)
    end

    def self.fingerprint(record)
      Digest::SHA256.hexdigest(JSON.generate(record.attributes.sort.to_h))
    end
    private_class_method :fingerprint

    def self.reject_sql(sql, error_class)
      rejected = false
      ActiveRecord::Base.connection.transaction(requires_new: true) do
        begin
          ActiveRecord::Base.connection.execute(sql)
        rescue ActiveRecord::StatementInvalid => error
          raise unless error.cause.is_a?(error_class)
          rejected = true
        end
        raise ActiveRecord::Rollback
      end
      raise "Current workflow accepted prohibited SQL" unless rejected
    end
    private_class_method :reject_sql

    def self.verify(manifest)
      manifest.fetch("records").each do |name, rows|
        raise "Missing #{name} fixture" if rows.empty?
        rows.each { |row| raise "Changed #{name} history" unless fingerprint(name.constantize.find(row.fetch("id"))) == row.fetch("digest") }
      end
      MODELS.each do |model|
        raise "Runtime lacks #{model.table_name} DML" unless ActiveRecord::Base.connection.select_value("SELECT has_table_privilege(current_user, '#{model.table_name}', 'SELECT,INSERT,UPDATE,DELETE')")
        field = if model == ModelFailureMatching
          "input='{}'::jsonb"
        elsif [ AssumptionImpact, TraceFailureDiscovery ].include?(model)
          "state='queued'"
        else
          "id=id"
        end
        reject_sql("UPDATE #{model.table_name} SET #{field}", PG::RaiseException)
        reject_sql("ALTER TABLE #{model.table_name} DISABLE TRIGGER ALL", PG::InsufficientPrivilege)
      end
      reject_sql("UPDATE scenarios SET parent_version_id=NULL WHERE id=#{manifest.fetch('variant')}", PG::RaiseException)
      reject_sql("UPDATE scenario_versions SET draft_notes='{}'::jsonb WHERE id=#{manifest.fetch('parent_version')}", PG::RaiseException)
      match = ModelFailureMatching.find(manifest.fetch("requests").fetch("ModelFailureMatching"))
      other = match.corpus.workspace.corpora.create!(name: "Foreign current-workflow proof")
      variant_version = Scenario.find(manifest.fetch("variant")).current_version_id
      reject_sql("INSERT INTO model_failure_matching_candidates (workspace_id, corpus_id, model_failure_matching_id, scenario_version_id) VALUES (#{other.workspace_id}, #{other.id}, #{match.id}, #{variant_version})", PG::ForeignKeyViolation)
      reject_sql("INSERT INTO assumption_impact_inputs (workspace_id, corpus_id, assumption_impact_id, scenario_version_id) VALUES (#{other.workspace_id}, #{other.id}, #{manifest.fetch('requests').fetch('AssumptionImpact')}, #{manifest.fetch('parent_version')})", PG::RaiseException)
      discovery = TraceFailureDiscovery.find(manifest.fetch("requests").fetch("TraceFailureDiscovery"))
      reject_sql("INSERT INTO trace_failure_discovery_inputs (workspace_id, corpus_id, trace_failure_discovery_id, corpus_item_id) VALUES (#{other.workspace_id}, #{other.id}, #{discovery.id}, #{match.corpus_item_id})", PG::ForeignKeyViolation)

      sent = false
      fixture(HttpTargetTestHelper, nil).with_test_method(EvaluationHttp, :call, ->(**) { sent = true; raise "Completed restored work sent again" }) do
        ModelFailureMatchingJob.perform_now(match.id)
        AssumptionImpactJob.perform_now(manifest.fetch("requests").fetch("AssumptionImpact"))
        TraceFailureDiscoveryJob.perform_now(discovery.id)
        manifest.fetch("records").fetch("CorpusAnalysis").each { |row| CorpusAnalysisJob.perform_now(row.fetch("id")) }
      end
      raise "Completed current workflows resent" if sent
      manifest.fetch("sources").each do |id|
        source = Source.find(id)
        source.update!(expires_at: 1.minute.ago)
        raise "Current source expiry" unless source.corpus.eval_definitions_expired?
        SourcePurge.call(source:)
        raise "Current purge audit" unless AuditEvent.where(action: "source.deleted", subject_type: "Source", subject_id: id).sole.metadata == {}
      end
      manifest.fetch("records").each do |name, rows|
        raise "Retained #{name} private copy after purge" if name.constantize.where(id: rows.pluck("id")).exists?
      end
      puts "PASS: current matching/impact/trace receipts, source-review notes/coupled variants, v2 observations and complete-text versions retain exact history under runtime; 12 new-table immutable/trigger guards, tenant lineage, no resend, expiry and corpus-wide purge."
    end

    def self.verify_queued(manifest)
      manifest.fetch("requests").each do |name, id|
        request = name.constantize.find(id)
        return false if request.state.in?(%w[queued running])
        raise "Unapproved native #{name} did not interrupt" unless request.state == "interrupted"
        result = case request
        when ModelFailureMatching then request.model_failure_matching_result
        when AssumptionImpact then request.assumption_impact_result
        when TraceFailureDiscovery then request.trace_failure_discovery_result
        end
        raise "Unapproved native #{name} retained a result" if result
      end
      true
    end
  end
end
