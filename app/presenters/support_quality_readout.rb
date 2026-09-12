class SupportQualityReadout
  OPEN_STATUSES = (SupportCase::STATUSES - %w[resolved closed]).freeze
  SIGNAL_KEYS = %w[
    sla_breaches reopened_cases_90d resolutions_without_proof_90d
    proofed_resolutions_90d recurring_issue_tags_90d
  ].freeze
  DETAIL_LIMIT = 20

  Metric = Data.define(:key, :label, :value, :detail, :tone)
  Row = Data.define(:title, :detail, :path)

  attr_reader :metrics, :breached_cases, :unproofed_accounts, :blocked_drafts

  def self.build(workspace:)
    new(workspace:).tap(&:build)
  end

  def initialize(workspace:)
    @workspace = workspace
  end

  def build
    @metrics = [
      metric("open_cases", "Open cases", open_cases_count, "Cases not resolved or closed."),
      metric("first_response_breaches", "First-response breaches",
        open_sla_count(first_response_status: "breached"), "Open cases past the first-response clock."),
      metric("resolution_breaches", "Resolution breaches",
        open_sla_count(resolution_status: "breached"), "Open cases past the resolution clock."),
      metric("reopened_90d", "Reopened in 90 days", signal_total("reopened_cases_90d"),
        "Sum of the latest retained reopen signal per Account."),
      metric("without_proof_90d", "Resolutions without proof", signal_total("resolutions_without_proof_90d"),
        "Sum of the latest retained unproofed-resolution signal per Account."),
      metric("proofed_90d", "Proofed resolutions", signal_total("proofed_resolutions_90d"),
        "Sum of the latest retained proofed-resolution signal per Account."),
      metric("blocked_drafts", "Blocked resolution drafts", blocked_draft_scope.count,
        "Current drafts whose contract result is blocked.")
    ]
    @breached_cases = open_breached_cases.map do |support_case|
      Row.new(
        title: support_case.conversation.subject,
        detail: sla_detail(support_case.case_sla),
        path: [ @workspace, support_case ]
      )
    end
    @unproofed_accounts = unproofed_signal_rows.map do |signal|
      account = signal.account_health_assessment.account
      Row.new(
        title: account.name,
        detail: "#{signal.numeric_value.to_i} #{'resolution'.pluralize(signal.numeric_value.to_i)} without contract proof in 90 days.",
        path: [ @workspace, account ]
      )
    end
    @blocked_drafts = blocked_draft_scope.includes(crew_task: { support_case: { conversation: :contact } })
      .order(id: :desc).limit(DETAIL_LIMIT).filter_map do |artifact|
      support_case = artifact.crew_task.support_case
      next unless support_case

      Row.new(
        title: support_case.conversation.subject,
        detail: "Draft contract #{artifact.contract_result_state.humanize}.",
        path: [ @workspace, support_case ]
      )
    end
    self
  end

  def attention?
    metrics.any? { |item| item.key != "proofed_90d" && item.key != "open_cases" && item.value.positive? }
  end

  private
    def metric(key, label, value, detail)
      tone = if key == "proofed_90d"
        value.positive? ? "healthy" : "neutral"
      elsif value.positive? && key != "open_cases"
        "attention"
      else
        "neutral"
      end
      Metric.new(key:, label:, value:, detail:, tone:)
    end

    def open_cases_count
      @workspace.support_cases.where(status: OPEN_STATUSES).count
    end

    def open_sla_count(**status)
      @workspace.case_slas.joins(:support_case).where(support_cases: { status: OPEN_STATUSES }, **status).count
    end

    def open_breached_cases
      @workspace.support_cases.joins(:case_sla).includes(:case_sla, conversation: :contact)
        .where(status: OPEN_STATUSES)
        .where("case_slas.first_response_status = 'breached' OR case_slas.resolution_status = 'breached'")
        .order(:id).limit(DETAIL_LIMIT)
    end

    def latest_assessment_ids
      @latest_assessment_ids ||= @workspace.account_health_assessments
        .select("DISTINCT ON (account_health_assessments.account_id) account_health_assessments.id")
        .reorder(Arel.sql("account_health_assessments.account_id ASC, account_health_assessments.calculated_at DESC, account_health_assessments.id DESC"))
    end

    def signal_total(key)
      @signal_totals ||= @workspace.account_health_signals
        .where(account_health_assessment_id: latest_assessment_ids, signal_key: SIGNAL_KEYS)
        .group(:signal_key).sum(:numeric_value)
      @signal_totals.fetch(key, 0).to_i
    end

    def unproofed_signal_rows
      @workspace.account_health_signals
        .includes(account_health_assessment: :account)
        .where(account_health_assessment_id: latest_assessment_ids, signal_key: "resolutions_without_proof_90d")
        .where("numeric_value > 0")
        .order(numeric_value: :desc, id: :desc)
        .limit(DETAIL_LIMIT)
    end

    def blocked_draft_scope
      @workspace.crew_artifacts
        .where(artifact_kind: "draft", contract_result_state: "blocked")
        .where.missing(:revisions)
    end

    def sla_detail(case_sla)
      parts = []
      parts << "first response breached" if case_sla.first_response_breached?
      parts << "resolution breached" if case_sla.resolution_breached?
      parts.join(" · ").presence || "SLA clock needs attention"
    end
end
