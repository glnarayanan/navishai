class SupportQualityReadout
  OPEN_STATUSES = (SupportCase::STATUSES - %w[resolved closed]).freeze
  SIGNAL_KEYS = %w[
    sla_breaches reopened_cases_90d resolutions_without_proof_90d
    proofed_resolutions_90d recurring_issue_tags_90d
  ].freeze
  DETAIL_LIMIT = 20
  WINDOW_DAYS = [ 7, 30, 90 ].freeze

  Metric = Data.define(:key, :label, :value, :detail, :tone)
  Window = Data.define(:days, :label, :metrics, :rows, :methodology)
  Row = Data.define(:title, :detail, :path, :artifact) do
    def initialize(title:, detail:, path:, artifact: nil)
      super(title:, detail:, path:, artifact:)
    end
  end

  attr_reader :metrics, :breached_cases, :unproofed_accounts, :blocked_drafts, :windows

  def self.build(workspace:, now: Time.current)
    new(workspace:, now:).tap(&:build)
  end

  def initialize(workspace:, now:)
    @workspace = workspace
    @now = now
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
    @blocked_drafts = blocked_draft_scope.includes(
      :knowledge_improvement_candidate, crew_task: { support_case: { conversation: :contact } }
    ).order(id: :desc).limit(DETAIL_LIMIT).filter_map do |artifact|
      support_case = artifact.crew_task.support_case
      next unless support_case

      Row.new(
        title: support_case.conversation.subject,
        detail: blocked_draft_detail(artifact),
        path: [ @workspace, support_case ],
        artifact:
      )
    end
    @windows = WINDOW_DAYS.map { |days| window_readout(days) }
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

    def blocked_draft_detail(artifact)
      if artifact.knowledge_improvement_candidate
        "Blocked draft · improvement candidate #{artifact.knowledge_improvement_candidate.status.humanize.downcase}."
      else
        "Draft contract #{artifact.contract_result_state.humanize}."
      end
    end

    def window_readout(days)
      starts_at = @now - days.days
      drafts = final_draft_scope.where(contract_evaluated_at: starts_at..@now)
      completed = artifact_evidence(drafts.where(contract_result_state: "complete"))
      blocked = artifact_evidence(drafts.where(contract_result_state: "blocked"))
      blockers = blocker_evidence(drafts.where(contract_result_state: "blocked"))
      reviews = review_evidence(starts_at)
      sends = sent_lineage_evidence(starts_at)
      intake_durations = intake_duration_evidence(starts_at)
      send_durations = send_duration_evidence(starts_at)
      cost = usage_and_cost(starts_at)

      Window.new(
        days:, label: "Last #{days} days",
        metrics: [
          Metric.new(key: "completed_drafts", label: "Completed draft artifacts", value: completed.fetch(:count),
            detail: evidence_detail(completed, "Latest draft revision evaluated complete in this window."), tone: "healthy"),
          Metric.new(key: "blocked_drafts", label: "Blocked draft artifacts", value: blocked.fetch(:count),
            detail: evidence_detail(blocked, "Latest draft revision evaluated blocked in this window."), tone: blocked.fetch(:count).positive? ? "attention" : "neutral"),
          Metric.new(key: "contract_failure_reasons", label: "Structured contract failure reasons", value: blockers.fetch(:counts).any? ? blockers.fetch(:counts).map { |code, count| "#{code} × #{count}" }.join(" · ") : "None",
            detail: evidence_detail(blockers, "Blocker codes from the counted blocked drafts; linked records below identify each code."), tone: blocked.fetch(:count).positive? ? "attention" : "neutral"),
          Metric.new(key: "changes_requested", label: "Review changes requested", value: reviews.fetch(:count),
            detail: evidence_detail(reviews, "Quality-review artifacts recorded as changes requested."), tone: reviews.fetch(:count).positive? ? "attention" : "neutral"),
          Metric.new(key: "human_sent_lineages", label: "Draft lineages human-sent", value: sends.fetch(:count),
            detail: evidence_detail(sends, "Distinct generated-draft revision lineages linked to a sent human delivery."), tone: "neutral"),
          duration_metric("intake_to_draft_ready", "Median intake to Draft Ready", intake_durations),
          duration_metric("draft_ready_to_human_send", "Median Draft Ready to human send", send_durations),
          Metric.new(key: "observed_usage", label: "Observed usage units", value: cost.fetch(:usage_label),
            detail: "Input and output units reported by contributing run snapshots only. #{cost.fetch(:usage_coverage_label)}", tone: "neutral"),
          Metric.new(key: "known_cost", label: "Known cost", value: cost.fetch(:cost_label),
            detail: cost.fetch(:coverage_label), tone: "neutral")
        ],
        rows: window_rows(completed:, blocked:, blockers:, reviews:, sends:, intake_durations:, send_durations:, cost:),
        methodology: methodology(days)
      )
    end

    def final_draft_scope
      @workspace.crew_artifacts.joins(:crew_task).where(
        artifact_kind: "draft", crew_tasks: { scope_kind: "support_case" }
      ).where.missing(:revisions)
    end

    def changes_requested_scope
      @workspace.crew_artifacts
        .joins("INNER JOIN crew_artifacts reviewed_drafts ON reviewed_drafts.id = crew_artifacts.target_artifact_id")
        .joins("INNER JOIN crew_tasks reviewed_draft_tasks ON reviewed_draft_tasks.id = reviewed_drafts.crew_task_id")
        .where(artifact_kind: "quality_review", review_outcome: "changes_requested")
        .where("reviewed_draft_tasks.scope_kind = ?", "support_case")
    end

    def artifact_evidence(scope)
      records = scope.includes(crew_task: { support_case: :conversation })
        .order(contract_evaluated_at: :desc, id: :desc).limit(DETAIL_LIMIT).to_a
      { count: scope.distinct.count, records: }
    end

    def blocker_evidence(blocked_scope)
      counts = blocker_counts(blocked_scope)
      artifacts = blocked_scope.where("jsonb_array_length(crew_artifacts.contract_blockers) > 0")
        .includes(crew_task: { support_case: :conversation }).order(contract_evaluated_at: :desc, id: :desc).limit(DETAIL_LIMIT).to_a
      records = artifacts.flat_map do |artifact|
        Array(artifact.contract_blockers).map { |blocker| { artifact:, blocker: } }
      end.first(DETAIL_LIMIT)
      { count: counts.values.sum, records:, counts: }
    end

    def blocker_counts(scope)
      @workspace.account_health_signals.connection.select_rows(<<~SQL.squish).to_h { |code, count| [ code, count.to_i ] }
        SELECT COALESCE(blocker->>'code', 'unclassified'), COUNT(*)
        FROM (#{scope.select(:id, :contract_blockers).to_sql}) blocked_drafts
        CROSS JOIN LATERAL jsonb_array_elements(blocked_drafts.contract_blockers) blocker
        GROUP BY 1
        ORDER BY 1
      SQL
    end

    def review_evidence(starts_at)
      scope = changes_requested_scope.where(created_at: starts_at..@now)
      records = scope.includes(target_artifact: { crew_task: { support_case: :conversation } }).order(created_at: :desc, id: :desc).limit(DETAIL_LIMIT).to_a
      { count: scope.distinct.count, records: }
    end

    def sent_lineage_evidence(starts_at)
      count = sent_lineage_rows(starts_at).count
      rows = sent_lineage_rows(starts_at, limit: DETAIL_LIMIT)
      artifacts = CrewArtifact.includes(crew_task: { support_case: :conversation }).where(id: rows.map { |row| row.fetch("artifact_id") }).index_by(&:id)
      records = rows.filter_map do |row|
        artifact = artifacts[row.fetch("artifact_id").to_i]
        artifact && { artifact:, sent_at: row.fetch("sent_at").in_time_zone }
      end
      { count:, records: }
    end

    def intake_duration_evidence(starts_at)
      scope = intake_duration_scope(starts_at)
      aggregate = duration_aggregate(scope)
      records = scope.order("duration_seconds DESC, support_case_id DESC").limit(DETAIL_LIMIT).map do |row|
        { case: SupportCase.includes(:conversation).find(row.support_case_id), duration: row.duration_seconds.to_f }
      end
      aggregate.merge(records:)
    end

    def send_duration_evidence(starts_at)
      aggregate = duration_aggregate(sent_duration_sql(starts_at))
      records = @workspace.account_health_signals.connection.select_all("#{sent_duration_sql(starts_at)} LIMIT #{DETAIL_LIMIT}").filter_map do |row|
        support_case = SupportCase.includes(:conversation).find_by(id: row.fetch("support_case_id"))
        support_case && { case: support_case, duration: row.fetch("duration_seconds").to_f, sent_at: row.fetch("sent_at").in_time_zone }
      end
      aggregate.merge(records:)
    end

    def usage_and_cost(starts_at)
      scope = @workspace.execution_runs.terminal.joins(:crew_task).where(
        crew_tasks: { scope_kind: "support_case" }, finished_at: starts_at..@now
      )
      aggregate = scope.left_joins(:usage_cost_snapshot).pick(
        Arel.sql("COUNT(execution_runs.id)"),
        Arel.sql("COALESCE(SUM(usage_cost_snapshots.observed_input_units), 0)"),
        Arel.sql("COALESCE(SUM(usage_cost_snapshots.observed_output_units), 0)"),
        Arel.sql("COUNT(usage_cost_snapshots.observed_input_units)"),
        Arel.sql("COUNT(usage_cost_snapshots.observed_output_units)"),
        Arel.sql("COUNT(usage_cost_snapshots.amount_micros)")
      ) || [ 0, 0, 0, 0, 0, 0 ]
      runs_count, input, output, input_count, output_count, known_count = aggregate.map(&:to_i)
      amounts = scope.joins(:usage_cost_snapshot).where.not(usage_cost_snapshots: { amount_micros: nil })
        .group("usage_cost_snapshots.currency").sum("usage_cost_snapshots.amount_micros")
      records = scope.includes(:usage_cost_snapshot).order(finished_at: :desc, id: :desc).limit(DETAIL_LIMIT).to_a
      {
        usage_label: usage_label(input:, output:, input_count:, output_count:),
        usage_coverage_label: "Input reported for #{input_count} of #{runs_count} terminal support runs; output reported for #{output_count} of #{runs_count}. #{evidence_coverage(runs_count, records.count)}",
        cost_label: amounts.any? ? amounts.map { |currency, amount| "#{format_micros(amount)} #{currency}" }.join(" · ") : "Unknown",
        coverage_label: "Known amount for #{known_count} of #{runs_count} terminal support runs; #{runs_count - known_count} have no known amount. #{evidence_coverage(runs_count, records.count)}",
        count: runs_count,
        records:
      }
    end

    def duration_metric(key, label, evidence)
      Metric.new(key:, label:, value: evidence.fetch(:count).positive? ? format_duration(evidence.fetch(:median)) : "—",
        detail: evidence.fetch(:count).positive? ? evidence_detail(evidence, "Attributable records used for this median.") : "No attributable records in this window.", tone: "neutral")
    end

    def window_rows(completed:, blocked:, blockers:, reviews:, sends:, intake_durations:, send_durations:, cost:)
      rows = completed.fetch(:records).filter_map { |artifact| row_for_artifact(artifact, "Completed draft") }
      rows.concat(blocked.fetch(:records).filter_map { |artifact| row_for_artifact(artifact, "Blocked draft") })
      rows.concat(blockers.fetch(:records).filter_map do |item|
        artifact = item.fetch(:artifact)
        support_case = artifact.crew_task.support_case
        next unless support_case

        Row.new(title: support_case.conversation.subject, detail: "Blocked draft · #{item.fetch(:blocker).fetch("code", "unclassified")}", path: [ @workspace, support_case ], artifact:)
      end)
      rows.concat(reviews.fetch(:records).filter_map { |review| row_for_artifact(review.target_artifact, "Review requested changes") })
      rows.concat(sends.fetch(:records).map { |item| row_for_artifact(item.fetch(:artifact), "Human sent #{item.fetch(:sent_at).to_fs(:short)}") })
      rows.concat(intake_durations.fetch(:records).map { |item| Row.new(title: item.fetch(:case).conversation.subject, detail: "Intake to Draft Ready · #{format_duration(item.fetch(:duration))}", path: [ @workspace, item.fetch(:case) ]) })
      rows.concat(send_durations.fetch(:records).map { |item| Row.new(title: item.fetch(:case).conversation.subject, detail: "Draft Ready to human send · #{format_duration(item.fetch(:duration))}", path: [ @workspace, item.fetch(:case) ]) })
      rows.concat(cost.fetch(:records).map { |run| Row.new(title: "Run #{run.run_key.to_s.first(8)}", detail: run.usage_cost_snapshot&.amount_micros.present? ? "Usage/cost snapshot recorded" : "Usage/cost amount unknown", path: outcome_path(run)) })
      rows
    end

    def row_for_artifact(artifact, detail)
      support_case = artifact&.crew_task&.support_case
      return unless support_case

      Row.new(title: support_case.conversation.subject, detail:, path: [ @workspace, support_case ], artifact:)
    end

    def format_duration(seconds)
      minutes = (seconds / 60.0).round
      "#{minutes / 60}h #{minutes % 60}m"
    end

    def format_micros(amount)
      format("%.6f", BigDecimal(amount.to_s) / 1_000_000)
    end

    def usage_label(input:, output:, input_count:, output_count:)
      return "Unknown" if input_count.zero? && output_count.zero?

      input_value = input_count.positive? ? input : "Unknown"
      output_value = output_count.positive? ? output : "Unknown"
      "#{input_value} in / #{output_value} out"
    end

    def evidence_detail(evidence, statement)
      "#{statement} #{evidence_coverage(evidence.fetch(:count), evidence.fetch(:records).count)}"
    end

    def evidence_coverage(count, shown)
      omitted = count - shown
      if omitted.positive?
        "#{shown} linked #{'record'.pluralize(shown)} shown; #{omitted} omitted by the per-category detail limit."
      else
        "#{shown} linked #{'record'.pluralize(shown)} shown; none omitted."
      end
    end

    def intake_duration_scope(starts_at)
      source = @workspace.support_case_status_changes.joins(:support_case)
        .where(to_status: "draft_ready", occurred_at: starts_at..@now)
        .where("support_case_status_changes.occurred_at >= support_cases.created_at")
        .select(<<~SQL.squish)
          DISTINCT ON (support_case_status_changes.support_case_id)
          support_case_status_changes.support_case_id,
          EXTRACT(EPOCH FROM support_case_status_changes.occurred_at - support_cases.created_at) AS duration_seconds
        SQL
        .order("support_case_status_changes.support_case_id, support_case_status_changes.occurred_at, support_case_status_changes.id")

      SupportCaseStatusChange.from("(#{source.to_sql}) intake_durations")
        .select("intake_durations.support_case_id, intake_durations.duration_seconds")
    end

    def sent_duration_sql(starts_at)
      <<~SQL.squish
        SELECT lineages.support_case_id, lineages.sent_at,
               EXTRACT(EPOCH FROM lineages.sent_at - ready_change.occurred_at) AS duration_seconds
        FROM (#{sent_lineage_sql(starts_at)}) lineages
        JOIN LATERAL (
          SELECT support_case_status_changes.occurred_at
          FROM support_case_status_changes
          WHERE support_case_status_changes.workspace_id = #{@workspace.id}
            AND support_case_status_changes.support_case_id = lineages.support_case_id
            AND support_case_status_changes.to_status = 'draft_ready'
            AND support_case_status_changes.occurred_at <= lineages.sent_at
          ORDER BY support_case_status_changes.occurred_at DESC, support_case_status_changes.id DESC
          LIMIT 1
        ) ready_change ON true
        ORDER BY duration_seconds DESC, lineages.support_case_id DESC
      SQL
    end

    def duration_aggregate(scope)
      sql = scope.is_a?(String) ? scope : scope.to_sql
      row = @workspace.account_health_signals.connection.select_one(<<~SQL.squish)
        SELECT COUNT(*) AS count,
               percentile_cont(0.5) WITHIN GROUP (ORDER BY duration_seconds) AS median
        FROM (#{sql}) duration_values
      SQL
      { count: row.fetch("count").to_i, median: row.fetch("median").to_f }
    end

    def sent_lineage_rows(starts_at, limit: nil)
      sql = "SELECT artifact_id, sent_at FROM (#{sent_lineage_sql(starts_at)}) sent_lineages ORDER BY sent_at DESC, artifact_id DESC"
      sql += " LIMIT #{limit.to_i}" if limit
      @workspace.account_health_signals.connection.select_all(sql)
    end

    def sent_lineage_sql(starts_at)
      starts_sql = @workspace.account_health_signals.connection.quote(starts_at)
      now_sql = @workspace.account_health_signals.connection.quote(@now)
      <<~SQL.squish
        WITH RECURSIVE delivery_sources AS (
          SELECT 'email' AS delivery_type, outbound_email_deliveries.id AS delivery_id,
                 outbound_email_deliveries.sent_at, outbound_email_deliveries.source_crew_artifact_id AS artifact_id,
                 crew_tasks.support_case_id
          FROM outbound_email_deliveries
          JOIN crew_artifacts ON crew_artifacts.id = outbound_email_deliveries.source_crew_artifact_id
          JOIN crew_tasks ON crew_tasks.id = crew_artifacts.crew_task_id
          WHERE outbound_email_deliveries.workspace_id = #{@workspace.id}
            AND outbound_email_deliveries.status = 'sent'
            AND outbound_email_deliveries.sent_at BETWEEN #{starts_sql} AND #{now_sql}
            AND crew_artifacts.workspace_id = #{@workspace.id}
            AND crew_tasks.workspace_id = #{@workspace.id}
            AND crew_tasks.scope_kind = 'support_case'
            AND crew_tasks.support_case_id IS NOT NULL
          UNION ALL
          SELECT 'intercom' AS delivery_type, intercom_outbound_deliveries.id AS delivery_id,
                 intercom_outbound_deliveries.sent_at, intercom_outbound_deliveries.source_crew_artifact_id AS artifact_id,
                 crew_tasks.support_case_id
          FROM intercom_outbound_deliveries
          JOIN crew_artifacts ON crew_artifacts.id = intercom_outbound_deliveries.source_crew_artifact_id
          JOIN crew_tasks ON crew_tasks.id = crew_artifacts.crew_task_id
          WHERE intercom_outbound_deliveries.workspace_id = #{@workspace.id}
            AND intercom_outbound_deliveries.status = 'sent'
            AND intercom_outbound_deliveries.sent_at BETWEEN #{starts_sql} AND #{now_sql}
            AND crew_artifacts.workspace_id = #{@workspace.id}
            AND crew_tasks.workspace_id = #{@workspace.id}
            AND crew_tasks.scope_kind = 'support_case'
            AND crew_tasks.support_case_id IS NOT NULL
        ), artifact_ancestors AS (
          SELECT delivery_type, delivery_id, sent_at, artifact_id, support_case_id,
                 artifact_id AS descendant_id, crew_artifacts.supersedes_artifact_id
          FROM delivery_sources
          JOIN crew_artifacts ON crew_artifacts.id = delivery_sources.artifact_id
          UNION ALL
          SELECT artifact_ancestors.delivery_type, artifact_ancestors.delivery_id, artifact_ancestors.sent_at,
                 artifact_ancestors.artifact_id, artifact_ancestors.support_case_id,
                 crew_artifacts.id AS descendant_id, crew_artifacts.supersedes_artifact_id
          FROM artifact_ancestors
          JOIN crew_artifacts ON crew_artifacts.id = artifact_ancestors.supersedes_artifact_id
        ), rooted_deliveries AS (
          SELECT delivery_type, delivery_id, sent_at, artifact_id, support_case_id, descendant_id AS lineage_id
          FROM artifact_ancestors
          WHERE supersedes_artifact_id IS NULL
        ), latest_per_lineage AS (
          SELECT *, ROW_NUMBER() OVER (
            PARTITION BY lineage_id ORDER BY sent_at DESC, delivery_type DESC, delivery_id DESC
          ) AS lineage_rank
          FROM rooted_deliveries
        )
        SELECT artifact_id, support_case_id, sent_at
        FROM latest_per_lineage
        WHERE lineage_rank = 1
      SQL
    end

    def methodology(days)
      "Window: the #{days * 24}-hour interval ending when this page is generated. Artifact, review, blocker-code, and sent-lineage values are record counts: their numerator is the qualifying record described on the card and they have no rate denominator. Each non-empty category retains up to #{DETAIL_LIMIT} linked records independently; card detail states the omitted count. Draft and blocker counts use only the latest artifact in each revision lineage and its contract-evaluated timestamp; superseded draft artifacts are excluded. Review counts use immutable quality-review creation timestamps and do not collapse review records. Human sends require a sent email or Intercom delivery with an exact source-draft link; failed, unknown, unsourced, and duplicate delivery attempts are excluded, and deliveries from any revision of one draft lineage collapse to one lineage. Intake-to-Draft-Ready uses the first Draft Ready transition in-window after case creation. Draft-Ready-to-send uses the latest preceding Draft Ready transition for each linked sent lineage. Duration values are median elapsed minutes; their denominator is the attributable-record count on the card. Usage and cost cover every terminal support run finished in-window, including retry runs and runs whose output artifact was later superseded: units are summed only when reported, known money is shown only from captured snapshot amounts, and cost coverage uses those runs as its denominator; runs without an amount remain unknown. These are observed workflow records, not time-saved, acceptance, or AI-resolution measures."
    end

    def outcome_path(run)
      Rails.application.routes.url_helpers.workspace_outcome_explanation_path(
        @workspace, subject_type: "run", subject_id: run.id
      )
    end
end
