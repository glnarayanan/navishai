class TraceFailureReview < ImmutableRecord
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :trace_failure_discovery
  belongs_to :corpus_item
  belongs_to :reviewed_by, class_name: "User"
  validates :decision, inclusion: { in: %w[accept reject uncertain] }
  validates :reason, length: { in: 1..2000 }
  validate -> { errors.add(:reason, "must explain the decision without null bytes") if reason.to_s.strip.empty? || reason.to_s.include?("\0") }

  def self.append!(discovery:, item:, membership:, decision:, reason:)
    discovery.corpus.with_lock do
      discovery.corpus.authorize_writer!(membership)
      discovery.reload
      discovery.ensure_evidence!
      finding = discovery.trace_failure_discovery_result&.result_content&.fetch("trace_accounts", [])&.find { |account| account["reference"] == "corpus-item-#{item.id}" }
      raise CorpusIntake::Invalid, "Choose a proposed failure from this completed discovery." unless discovery.state == "complete" && finding&.fetch("decision") == "proposed_failure" && discovery.corpus_items.exists?(item.id)
      record = create!(workspace: discovery.workspace, corpus: discovery.corpus, trace_failure_discovery: discovery, corpus_item: item, reviewed_by: membership.user,
        decision:, reason:, created_at: Time.current)
      AuditEvent.record!(action: "trace.failure_reviewed", source: :web, workspace: discovery.workspace, actor: membership.user, subject: record)
      record
    end
  end

  def authorize_draft!(item:, membership:)
    raise Scenario::Invalid, "Accept this proposed failure yourself before creating a draft." unless persisted? && corpus_item_id == item.id &&
      reviewed_by_id == membership.user_id && decision == "accept" &&
      trace_failure_discovery.trace_failure_reviews.where(corpus_item_id:, reviewed_by_id:).order(id: :desc).first.id == id
    raise Scenario::Invalid, "Discovery evidence expired or changed." if trace_failure_discovery.expired? || trace_failure_discovery.stale?
    # A draft deliberately changes the current definition set; acceptance remains
    # a historical decision, not a source-processing grant or approved expectation.
    SupportTrace.payload(item)
  end

  def source_excerpt
    finding = trace_failure_discovery.trace_failure_discovery_result.result_content.fetch("trace_accounts").find { |account| account["reference"] == "corpus-item-#{corpus_item_id}" }
    finding.fetch("evidence").find { |quote| quote["reference"] == "corpus-item-#{corpus_item_id}" }.fetch("quote")
  end
end
