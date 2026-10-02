class TraceScenarioDecision < ImmutableRecord
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :corpus_item
  belongs_to :scenario_version
  belongs_to :reviewed_by, class_name: "User"
  validates :decision, inclusion: { in: %w[match different uncertain] }
  validates :reason, length: { in: 1..2000 }
  validate -> { errors.add(:reason, "must explain the decision without null bytes") if reason.to_s.strip.empty? || reason.to_s.include?("\0") }

  def self.append!(item:, version:, membership:, decision:, reason:)
    corpus = item.corpus
    corpus.with_lock do
      corpus.authorize_writer!(membership)
      trace = SupportTrace.payload(item)
      raise Scenario::Invalid, "This trace has no reported failure." if trace["observed_failure"].blank?
      raise Scenario::Invalid, "Corpus source evidence expired." if corpus.eval_definitions_expired?
      raise Scenario::Invalid, "Choose a current, unmerged scenario with fresh evidence in this corpus." unless
        version.corpus_id == corpus.id && version.workspace_id == corpus.workspace_id && TraceScenarioMatching.eligible?(version)
      record = create!(workspace: corpus.workspace, corpus:, corpus_item: item, scenario_version: version,
        reviewed_by: membership.user, decision:, reason:, created_at: Time.current)
      AuditEvent.record!(action: "trace.scenario_decided", source: :web, workspace: corpus.workspace, actor: membership.user, subject: record)
      record
    end
  end
end
