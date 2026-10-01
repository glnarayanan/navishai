# Run only by bin/prove-upgrade, against its generated disposable database.
require "active_record/fixtures"
require Rails.root.join("test/test_helpers/recorded_evaluation_test_helper")

phase, manifest = ARGV
raise "Unknown proof phase" unless %w[seed verify].include?(phase) && manifest

if phase == "seed"
  ActiveRecord::FixtureSet.create_fixtures(Rails.root.join("test/fixtures"), %w[organizations workspaces users memberships])
  fixture = Object.new.extend(RecordedEvaluationTestHelper)
  fixture.define_singleton_method(:memberships) { |name| Membership.find(ActiveRecord::FixtureSet.identify(name)) }
  fixture.build_compared_evaluation
  corpus = fixture.instance_variable_get(:@corpus)
  membership = fixture.instance_variable_get(:@membership)
  fixed_case = fixture.instance_variable_get(:@case)
  check = fixed_case.eval_case_checks.find_by!(grader_version_id: fixture.instance_variable_get(:@action_grader).current_version_id)
  set = CalibrationSet.define!(corpus:, membership:, name: "Upgrade held-out fixture", grader_version_id: check.grader_version_id)
  sample = set.add_sample!(membership:, check_id: check.id, cohort: "held_out", output: fixture.instance_variable_get(:@trace_item).context.fetch("support_trace").fetch("output"))
  label = sample.label!(membership:, previous_id: nil, decision: "fail", rationale: "Synthetic expert: collect expiry first.")
  CorpusIntake.call(corpus:, membership:, name: "Upgrade historical conversations", kind: "conversations",
    bytes: [ { id: "old-sso", title: "Old SSO fixture", content: "SAML certificate expired; request expiry before changing configuration." } ].to_json)
  analysis = CorpusAnalysis.request!(corpus:, membership:, scenario_limit: 1)
  CorpusAnalysisJob.perform_now(analysis.id)
  raise "Analysis fixture: #{analysis.error}" unless analysis.reload.state == "complete"
  ids = { workspace: corpus.workspace_id, corpus: corpus.id, membership: membership.id, case: fixed_case.id,
    before: fixture.instance_variable_get(:@before).id, after: fixture.instance_variable_get(:@after).id,
    trace: fixture.instance_variable_get(:@trace_item).id, sample: sample.id, label: label.id, analysis: analysis.id }
  File.write(manifest, JSON.generate(ids), perm: 0o600)
  puts "PASS: old code seeded exact tenant/source/case/approval/fail/pass/held-out-label and completed local-analysis lineage."
else
  ids = JSON.parse(File.read(manifest))
  corpus = Corpus.find(ids.fetch("corpus"))
  membership = Membership.find(ids.fetch("membership"))
  fixed_case = EvalCase.find(ids.fetch("case"))
  before = EvaluationRun.find(ids.fetch("before"))
  after = EvaluationRun.find(ids.fetch("after"))
  trace = CorpusItem.find(ids.fetch("trace"))
  sample = CalibrationSample.find(ids.fetch("sample"))
  label = HumanLabel.find(ids.fetch("label"))
  analysis = CorpusAnalysis.find(ids.fetch("analysis"))
  failure = before.evaluation_results.sole
  success = after.evaluation_results.sole
  raise "Fixed case/results" unless failure.status == "fail" && success.status == "pass" &&
    before.evaluation_run_items.sole.eval_case_id == fixed_case.id && after.evaluation_run_items.sole.eval_case_id == fixed_case.id
  raise "Source/case/approval lineage" unless fixed_case.scenario_review.decision == "approve" &&
    before.evaluation_target_version.trace_item_id == trace.id && trace.workspace_id == corpus.workspace_id && trace.corpus_id == corpus.id &&
    fixed_case.workspace_id == corpus.workspace_id && fixed_case.corpus_id == corpus.id
  raise "Label lineage" unless sample.cohort == "held_out" && sample.eval_case_id == fixed_case.id &&
    label.calibration_sample_id == sample.id && label.decision == "fail" && label.labelled_by_id == membership.user_id
  count = EvaluationResult.count
  EvaluationRunJob.perform_now(before.id)
  CorpusAnalysisJob.perform_now(analysis.id)
  raise "Repeated completed delivery" unless EvaluationResult.count == count && analysis.reload.state == "complete"

  connection = ActiveRecord::Base.connection
  reject = lambda do |sql, error_class|
    rejected = false
    connection.transaction(requires_new: true) do
      begin
        connection.execute(sql)
      rescue ActiveRecord::StatementInvalid => error
        raise unless error.cause.is_a?(error_class)
        rejected = true
      end
      raise ActiveRecord::Rollback
    end
    raise "Prohibited SQL accepted" unless rejected
  end
  %w[source_snapshots corpus_items scenario_versions scenario_evidence scenario_reviews eval_cases eval_case_checks grader_versions calibration_sets calibration_samples human_labels evaluation_target_versions evaluation_results].each do |table|
    raise "Missing fixture for #{table}" unless connection.select_value("SELECT count(*) FROM #{table}").positive?
    reject.call("UPDATE #{table} SET id=id", PG::RaiseException)
  end
  foreign_workspace = Workspace.where.not(id: corpus.workspace_id).first!
  [ foreign_workspace, corpus.workspace ].each do |workspace|
    other = workspace.corpora.create!(name: "Foreign upgrade corpus")
    reject.call("INSERT INTO scenario_evidence (workspace_id, corpus_id, scenario_version_id, corpus_item_id, kind, excerpt) VALUES (#{workspace.id}, #{other.id}, #{fixed_case.scenario_version_id}, #{trace.id}, 'knowledge', 'Synthetic only')", PG::ForeignKeyViolation)
  end
  reject.call("UPDATE audit_events SET action=action", PG::RaiseException)
  reject.call("ALTER TABLE audit_events DISABLE TRIGGER ALL", PG::InsufficientPrivilege)

  if SourceSnapshot.column_names.include?("mask_digest")
    raise "Migrated historical mask policy" if corpus.source_snapshots.where.not(mask_count: 0, mask_digest: Digest::SHA256.hexdigest("[]")).exists?
    snapshot = CorpusIntake.call(corpus:, membership:, name: "Post-upgrade exact masking", kind: "document", bytes: "Synthetic Contact needs expiry.", redaction: "exact", redaction_values: "Synthetic Contact")
    raise "New schema behavior" unless snapshot.mask_count == 1 && snapshot.corpus_items.sole.content == "[text redacted] needs expiry."
  end
  source = trace.source_snapshot.source
  source.update!(expires_at: 1.minute.ago)
  raise "Expiry gate" unless corpus.reload.eval_definitions_expired? && source.dependent_versions.empty?
  begin
    sample.label!(membership:, previous_id: label.id, decision: "pass", rationale: "Expired proof must not write a label.")
    raise "Expired sample accepted a label"
  rescue EvalCase::Invalid => error
    raise unless error.message.include?("Source retention ended")
  end
  SourcePurge.call(source:)
  raise "Purge gate" if CorpusItem.exists?(trace.id) || EvalCase.exists?(fixed_case.id) || HumanLabel.exists?(label.id) || EvaluationResult.where(id: [ failure.id, success.id ]).exists?
  raise "Purge audit" unless AuditEvent.where(workspace_id: corpus.workspace_id, action: "source.deleted", subject_type: "Source", subject_id: source.id).sole.metadata == {}
  puts "PASS: real runtime grants, fixed lineage/results/labels/no resend, 13 SQL immutable-table guards, both tenant/corpus FK boundaries, audit protection, expiry and purge."
end
