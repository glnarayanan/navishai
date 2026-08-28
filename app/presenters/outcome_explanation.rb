class OutcomeExplanation
  SUBJECT_TYPES = %w[case account run health-assessment].freeze
  SUMMARY_TASK_STATUSES = %w[blocked review_requested failed in_progress].freeze
  DETAIL_LIMITS = {
    tasks: 40, runs: 40, artifacts: 80, task_events: 120, run_events: 240,
    searches: 50, search_results: 100, extractions: 100, memory_selections: 100,
    signals: 50, investigations: 50, email_drafts: 50, email_deliveries: 50,
    intercom_drafts: 50, intercom_deliveries: 50, communication_reviews: 100,
    recovery_events: 100, cost_snapshots: 100
  }.freeze
  DETAIL_LABELS = {
    tasks: "specialist tasks", runs: "execution runs", artifacts: "crew artifacts",
    task_events: "task events", run_events: "run events", searches: "public searches",
    search_results: "search results", extractions: "search extractions",
    memory_selections: "selected memory records", signals: "health signals",
    investigations: "risk investigations", email_drafts: "email drafts",
    email_deliveries: "email deliveries", intercom_drafts: "Intercom drafts",
    intercom_deliveries: "Intercom deliveries", communication_reviews: "send decisions",
    recovery_events: "recovery events", cost_snapshots: "cost snapshots"
  }.freeze
  Usage = Struct.new(
    :state, :run_state, :search_state, :input_units, :output_units, :search_units,
    :budget_units, :budget_used_units, :cost_state, :amounts_by_currency,
    :cost_snapshots, :run_count, :search_count, :cost_snapshot_count,
    :has_configured_estimates, :has_adapter_amounts, keyword_init: true
  )

  attr_reader :workspace, :membership, :subject_type, :subject, :tasks, :runs, :artifacts,
    :task_events, :searches, :memory_selections, :assessment, :signals, :investigations,
    :email_drafts, :email_deliveries, :intercom_drafts, :intercom_deliveries,
    :communication_reviews, :recovery_events, :usage, :omitted_counts

  def self.resolve!(workspace:, membership:, subject_type:, subject_id:)
    raise ActiveRecord::RecordNotFound unless subject_type.in?(SUBJECT_TYPES)

    subject = case subject_type
    when "case"
      workspace.support_cases.includes(assigned_membership: :user, conversation: { contact: :account }).find(subject_id)
    when "account" then workspace.accounts.find(subject_id)
    when "run" then workspace.execution_runs.includes(crew_task: [ :support_case, :account ]).find(subject_id)
    when "health-assessment"
      workspace.account_health_assessments.includes(
        :account, :health_scorecard_version, risk_investigation: :crew_task
      ).find(subject_id)
    end
    new(workspace:, membership:, subject_type:, subject:).tap(&:load)
  end

  def initialize(workspace:, membership:, subject_type:, subject:)
    @workspace = workspace
    @membership = workspace.memberships.find(membership.id)
    @subject_type = subject_type
    @subject = subject
    @omitted_counts = {}
  end

  def load
    @usage = build_usage
    load_task_and_run_detail
    load_research_detail
    load_memory
    load_health
    load_communication
    load_recovery
    load_cost_detail
    self
  end

  def title
    case subject
    when SupportCase then subject.conversation.subject.presence || "Case ##{subject.id}"
    when Account then subject.name
    when ExecutionRun then "Run #{subject.run_key.to_s.first(8)}"
    when AccountHealthAssessment then "#{subject.account.name} health snapshot"
    end
  end

  def subject_label
    case subject_type
    when "case" then "Support case"
    when "account" then "Account"
    when "run" then "Execution run"
    when "health-assessment" then "Health assessment"
    end
  end

  def outcome
    if subject.is_a?(ExecutionRun)
      subject.status.humanize
    elsif subject.is_a?(SupportCase)
      subject.status.humanize
    elsif assessment
      "#{assessment.risk_level.humanize} · #{assessment.score}/100"
    else
      "No outcome recorded"
    end
  end

  def outcome_state
    return "degraded" if runs.any? { |run| run.failed? || run.timed_out? || run.memory_degraded? || run.last_admission_error.present? }
    return "blocked" if runs.any?(&:policy_denied?)
    return latest_artifact.contract_result_state if latest_artifact&.contract_result_state
    return "blocked" if task_status_count("blocked").positive?
    return "complete" if subject.is_a?(ExecutionRun) && subject.completed?
    return "complete" if subject.is_a?(SupportCase) && (subject.status_resolved? || subject.status_closed?)
    return "complete" if assessment && active_task_count.zero?
    return "empty" if task_count.zero? && assessment.nil?

    "in_progress"
  end

  def blockers
    artifact_blockers = artifacts.flat_map(&:contract_blockers)
    task_blockers = tasks.filter_map do |task|
      next unless task.blocked? || task.failed? || task.review_requested?

      {
        "code" => "task_#{task.status}",
        "message" => "#{task.title} is #{task.status.humanize.downcase}.",
        "remediation" => task.review_requested? ? "A Manager must record the review decision." : "Review the task record and choose the next human action."
      }
    end
    run_blockers = runs.filter_map do |run|
      next unless run.failure_code || run.last_admission_error

      code = run.failure_code || run.last_admission_error
      {
        "code" => code,
        "message" => "Run attempt #{run.attempt_number} recorded #{code.humanize.downcase}.",
        "remediation" => run.admitting? ? "Reconcile the same request before starting another attempt." : "Review the terminal run before retrying."
      }
    end
    (artifact_blockers + task_blockers + run_blockers).uniq { |blocker| [ blocker["code"], blocker["message"] ] }
  end

  def freshness
    evidence = artifacts.flat_map(&:material_claims).flat_map { |claim| claim.fetch("evidence", []) }
    return "No proof data" if evidence.empty?
    return "Conflicted" if evidence.any? { |item| item["status"] == "conflicted" }
    return "Stale" if evidence.any? { |item| item["status"].in?(%w[stale expired superseded deleted unavailable]) }
    return "Stale" if evidence.any? { |item| parse_time(item["fresh_until"])&.<(Time.current) }
    return "Uncertain" if artifacts.any? { |artifact| artifact.material_claims.any? { |claim| claim["state"] != "supported" } }

    "Current"
  end

  def responsible_actor
    if subject.is_a?(SupportCase) && subject.assigned_membership
      subject.assigned_membership.user.email_address
    elsif tasks.first
      tasks.first.owner_user.email_address
    else
      "No owner assigned"
    end
  end

  def next_action
    return "No further action is recorded." if final_delivery
    return blockers.first.fetch("remediation") if blockers.any?
    return "Review the exact human message and press Send only when it is ready." if pending_draft?
    return "Continue the active specialist task." if task_status_count("in_progress").positive?
    return "Start the detected risk investigation." if investigations.any?(&:detected?)
    return "Create bounded crew work from current evidence." if task_count.zero?

    "Review the latest outcome and record the next human-owned step."
  end

  def latest_artifact = artifacts.first

  def reviews
    artifacts.select { |artifact| CrewArtifact::REVIEW_KINDS.include?(artifact.artifact_kind) }
  end

  def final_delivery
    (email_deliveries + intercom_deliveries).select(&:sent?).max_by { |delivery| delivery.sent_at || delivery.updated_at }
  end

  def memory_visible? = membership.can_inspect_memory?

  def run_search_attribution? = subject_type != "run"

  def run_events_for(run) = @run_events_by_run.fetch(run.id, [])

  def search_results_for(search) = @search_results_by_search.fetch(search.id, [])

  def extractions_for(result) = @extractions_by_result.fetch(result.id, [])

  def memory_superseded?(memory) = @superseded_memory_ids.include?(memory.id)

  def omitted_history
    omitted_counts.filter_map do |key, count|
      [ DETAIL_LABELS.fetch(key), count ] if count.positive?
    end
  end

  private
    def task_scope
      @task_scope ||= case subject
      when SupportCase then workspace.crew_tasks.where(support_case: subject)
      when Account then workspace.crew_tasks.where(account: subject).or(workspace.crew_tasks.where(support_case_id: account_case_ids))
      when ExecutionRun then workspace.crew_tasks.where(id: subject.crew_task_id)
      when AccountHealthAssessment
        task_id = subject.risk_investigation&.crew_task_id
        workspace.crew_tasks.where(id: task_id)
      end
    end

    def run_scope
      scope = workspace.execution_runs.where(crew_task_id: task_scope.select(:id))
      subject.is_a?(ExecutionRun) ? scope.where(id: subject.id) : scope
    end

    def search_scope
      return workspace.public_web_searches.none if subject.is_a?(ExecutionRun)

      workspace.public_web_searches.where(crew_task_id: task_scope.select(:id))
    end

    def account_case_ids
      workspace.support_cases.joins(conversation: :contact).where(contacts: { account_id: subject.id }).select(:id)
    end

    def relevant_case_scope
      case subject
      when SupportCase then workspace.support_cases.where(id: subject.id)
      when Account then workspace.support_cases.where(id: account_case_ids)
      when ExecutionRun then workspace.support_cases.where(id: subject.crew_task.support_case_id)
      else workspace.support_cases.none
      end
    end

    def load_task_and_run_detail
      @task_status_counts = task_scope.group(:status).count
      task_limit = DETAIL_LIMITS.fetch(:tasks)
      summary_task_ids = task_scope.where(status: SUMMARY_TASK_STATUSES)
        .order(Arel.sql(<<~SQL.squish), created_at: :desc, id: :desc)
          CASE status
          WHEN 'blocked' THEN 0
          WHEN 'review_requested' THEN 1
          WHEN 'failed' THEN 2
          WHEN 'in_progress' THEN 3
          ELSE 4 END
        SQL
        .limit(task_limit).pluck(:id)
      run_task_ids = if summary_task_ids.size < task_limit
        run_scope.where.not(crew_task_id: summary_task_ids)
          .group(:crew_task_id)
          .order(Arel.sql("MAX(execution_runs.created_at) DESC"), Arel.sql("MAX(execution_runs.id) DESC"))
          .limit(task_limit - summary_task_ids.size).pluck(:crew_task_id)
      else
        []
      end
      selected_task_ids = summary_task_ids + run_task_ids
      if selected_task_ids.size < task_limit
        selected_task_ids += task_scope.where.not(id: selected_task_ids)
          .order(created_at: :desc, id: :desc).limit(task_limit - selected_task_ids.size).pluck(:id)
      end
      selected_tasks = task_scope.where(id: selected_task_ids)
        .includes(:support_case, :account, :assigned_agent_profile, :owner_user, :current_event)
        .index_by(&:id)
      @tasks = selected_task_ids.filter_map { |id| selected_tasks[id] }
      omitted_counts[:tasks] = [ task_count - @tasks.size, 0 ].max
      @runs = limited_records(
        run_scope.where(crew_task_id: selected_task_ids).includes(
          :agent_profile, :agent_profile_version, :current_event, :usage_rate_version
        ).order(created_at: :desc, id: :desc),
        :runs, total: usage.run_count
      )
      artifact_scope = workspace.crew_artifacts.where(execution_run_id: run_scope.select(:id))
      @artifacts = limited_records(
        workspace.crew_artifacts.where(execution_run_id: @runs.map(&:id))
          .includes(:resolution_contract_version, :target_artifact, :execution_run)
          .order(created_at: :desc, id: :desc),
        :artifacts, total: artifact_scope.count
      )
      task_event_scope = workspace.crew_task_events.where(crew_task_id: task_scope.select(:id))
      @task_events = limited_records(
        workspace.crew_task_events.where(crew_task_id: @tasks.map(&:id))
          .select(:id, :crew_task_id, :event_kind, :source, :actor_user_id, :to_agent_profile_id,
            :review_outcome, :created_at)
          .includes(:actor_user, :to_agent_profile).order(created_at: :desc, id: :desc),
        :task_events, total: task_event_scope.count
      )
      run_event_scope = workspace.execution_events.where(execution_run_id: run_scope.select(:id))
      run_events = limited_records(
        workspace.execution_events.where(execution_run_id: @runs.map(&:id))
          .select(:id, :execution_run_id, :event_type, :sequence_number, :occurred_at)
          .order(occurred_at: :desc, id: :desc),
        :run_events, total: run_event_scope.count
      )
      @run_events_by_run = run_events.group_by(&:execution_run_id).transform_values do |events|
        events.sort_by(&:sequence_number)
      end
    end

    def load_research_detail
      @searches = limited_records(
        search_scope.includes(:usage_rate_version, :requested_by_user)
          .order(created_at: :desc, id: :desc),
        :searches, total: usage.search_count
      )
      result_scope = workspace.public_web_search_results.where(public_web_search_id: search_scope.select(:id))
      results = limited_records(
        workspace.public_web_search_results.where(public_web_search_id: @searches.map(&:id))
          .select(:id, :public_web_search_id, :rank, :citation_key, :title, :url, :retrieved_at)
          .order(retrieved_at: :desc, id: :desc),
        :search_results, total: result_scope.count
      )
      @search_results_by_search = results.group_by(&:public_web_search_id).transform_values do |values|
        values.sort_by(&:rank)
      end
      extraction_scope = workspace.public_web_extractions.where(public_web_search_result_id: result_scope.select(:id))
      extractions = limited_records(
        workspace.public_web_extractions.where(public_web_search_result_id: results.map(&:id))
          .select(:id, :public_web_search_result_id, :status, :failure_code, :created_at)
          .order(created_at: :desc, id: :desc),
        :extractions, total: extraction_scope.count
      )
      @extractions_by_result = extractions.group_by(&:public_web_search_result_id)
    end

    def load_memory
      unless memory_visible?
        @memory_selections = []
        return
      end

      allowed_ids = MemoryGovernance.accessible_records(workspace, membership).select(:id)
      selection_scope = workspace.execution_memory_selections
        .where(execution_run_id: run_scope.select(:id), memory_record_id: allowed_ids)
      @memory_selections = limited_records(
        workspace.execution_memory_selections
          .where(execution_run_id: @runs.map(&:id), memory_record_id: allowed_ids)
          .includes(memory_record: :memory_tombstone)
          .order(created_at: :desc, id: :desc),
        :memory_selections, total: selection_scope.count
      )
      selected_ids = @memory_selections.map(&:memory_record_id)
      @superseded_memory_ids = workspace.memory_records.where(supersedes_memory_record_id: selected_ids)
        .distinct.pluck(:supersedes_memory_record_id).to_set
    end

    def load_health
      @assessment = case subject
      when AccountHealthAssessment then subject
      when Account
        subject.health_assessments.includes(:health_scorecard_version, risk_investigation: :crew_task).first
      when SupportCase
        subject.conversation.contact.account&.health_assessments&.includes(
          :health_scorecard_version, risk_investigation: :crew_task
        )&.first
      when ExecutionRun
        subject.crew_task.account&.health_assessments&.includes(
          :health_scorecard_version, risk_investigation: :crew_task
        )&.first
      end
      @signals = if @assessment
        limited_records(@assessment.signals.order(:id), :signals)
      else
        []
      end
      account = @assessment&.account || (subject if subject.is_a?(Account))
      @investigations = if account
        limited_records(
          account.risk_investigations.includes(:crew_task, :account_health_assessment)
            .order(opened_at: :desc, id: :desc),
          :investigations
        )
      else
        []
      end
    end

    def load_communication
      case_ids = relevant_case_scope.select(:id)
      email_draft_scope = workspace.email_drafts.where(support_case_id: case_ids)
      @email_drafts = limited_records(
        email_draft_scope.includes(:updated_by, :human_edited_by_user, :source_crew_artifact)
          .order(updated_at: :desc, id: :desc),
        :email_drafts
      )
      email_delivery_scope = workspace.outbound_email_deliveries.joins(:email_draft)
        .where(email_drafts: { support_case_id: case_ids })
      @email_deliveries = limited_records(
        email_delivery_scope.includes(:actor_user, :human_edited_by_user, :source_crew_artifact)
          .order(started_at: :desc, id: :desc),
        :email_deliveries
      )
      intercom_draft_scope = workspace.intercom_drafts.where(support_case_id: case_ids)
      @intercom_drafts = limited_records(
        intercom_draft_scope.includes(:updated_by, :human_edited_by_user, :source_crew_artifact)
          .order(updated_at: :desc, id: :desc),
        :intercom_drafts
      )
      intercom_delivery_scope = workspace.intercom_outbound_deliveries.joins(:intercom_draft)
        .where(intercom_drafts: { support_case_id: case_ids })
      @intercom_deliveries = limited_records(
        intercom_delivery_scope.includes(:actor_user, :human_edited_by_user, :source_crew_artifact)
          .order(started_at: :desc, id: :desc),
        :intercom_deliveries
      )
      review_base = workspace.audit_events.where(action: %w[email.send_reviewed intercom.send_reviewed])
      all_reviews = review_base.where(subject_type: "OutboundEmailDelivery", subject_id: email_delivery_scope.select(:id))
        .or(review_base.where(subject_type: "IntercomOutboundDelivery", subject_id: intercom_delivery_scope.select(:id)))
      visible_reviews = review_base.where(subject_type: "OutboundEmailDelivery", subject_id: @email_deliveries.map(&:id))
        .or(review_base.where(subject_type: "IntercomOutboundDelivery", subject_id: @intercom_deliveries.map(&:id)))
      @communication_reviews = limited_records(
        visible_reviews.includes(:actor).order(occurred_at: :desc, id: :desc),
        :communication_reviews, total: all_reviews.count
      )
    end

    def load_recovery
      recovery_scope = workspace.audit_events.where(
        subject_type: "ExecutionRun", subject_id: run_scope.select(:id),
        action: %w[execution.run_requested execution.run_reconciled]
      )
      @recovery_events = limited_records(
        workspace.audit_events.where(
          subject_type: "ExecutionRun", subject_id: @runs.map(&:id),
          action: %w[execution.run_requested execution.run_reconciled]
        ).includes(:actor).order(occurred_at: :desc, id: :desc),
        :recovery_events, total: recovery_scope.count
      )
    end

    def build_usage
      run_count, budget_units = run_scope.pick(
        Arel.sql("COUNT(*)"), Arel.sql("COALESCE(SUM(max_input_units + max_output_units), 0)")
      ) || [ 0, 0 ]
      run_count = run_count.to_i
      budget_units = budget_units.to_i
      reported_runs = run_scope.where(<<~SQL.squish, workspace.id)
        EXISTS (
          SELECT 1 FROM execution_events
          WHERE execution_events.execution_run_id = execution_runs.id
            AND execution_events.workspace_id = ?
            AND execution_events.event_type = 'usage.observed'
        )
      SQL
      reported_count, input_units, output_units, budget_used_units = reported_runs.pick(
        Arel.sql("COUNT(*)"), Arel.sql("COALESCE(SUM(input_units), 0)"),
        Arel.sql("COALESCE(SUM(output_units), 0)"),
        Arel.sql("COALESCE(SUM(input_units + output_units), 0)")
      ) || [ 0, 0, 0, 0 ]
      reported_count = reported_count.to_i
      input_units = input_units.to_i
      output_units = output_units.to_i
      budget_used_units = budget_used_units.to_i
      run_state = reporting_state(run_count, reported_count)
      input_units = nil if reported_count.zero?
      output_units = nil if reported_count.zero?

      search_count, reported_search_count, search_units = search_scope.pick(
        Arel.sql("COUNT(*)"),
        Arel.sql("COUNT(*) FILTER (WHERE public_web_searches.status = 'completed')"),
        Arel.sql("COALESCE(SUM(cost_units) FILTER (WHERE public_web_searches.status = 'completed'), 0)")
      ) || [ 0, 0, 0 ]
      search_count = search_count.to_i
      reported_search_count = reported_search_count.to_i
      search_units = search_units.to_i
      search_state = run_search_attribution? ? reporting_state(search_count, reported_search_count) : "unavailable"
      search_units = nil if reported_search_count.zero?

      statuses = cost_snapshot_scope.group(:status).count
      sources = cost_snapshot_scope.where.not(source: nil).group(:source).count
      amounts = cost_snapshot_scope.where(
        "status = 'complete' OR (status = 'partial' AND amount_micros > 0)"
      ).group(:currency).sum(:amount_micros)
      snapshot_count = statuses.values.sum
      cost_state = cost_state(statuses, snapshot_count, run_count + search_count, amounts)
      states = [ run_state, search_state ].reject { |state| state == "unavailable" && !run_search_attribution? }
      Usage.new(
        state: combined_state(states), run_state:, search_state:,
        input_units:, output_units:, search_units:,
        budget_units:, budget_used_units:,
        cost_state:, amounts_by_currency: amounts, cost_snapshots: [],
        run_count:, search_count:, cost_snapshot_count: snapshot_count,
        has_configured_estimates: sources.fetch("configured_rate", 0).positive?,
        has_adapter_amounts: sources.fetch("adapter_reported", 0).positive?
      )
    end

    def load_cost_detail
      usage.cost_snapshots = limited_records(
        cost_snapshot_scope.includes(:execution_run, :public_web_search, :applied_usage_rate_version)
          .order(captured_at: :desc, id: :desc),
        :cost_snapshots, total: usage.cost_snapshot_count
      )
    end

    def cost_snapshot_scope
      @cost_snapshot_scope ||= begin
        runs = workspace.usage_cost_snapshots.where(execution_run_id: run_scope.select(:id))
        searches = workspace.usage_cost_snapshots.where(public_web_search_id: search_scope.select(:id))
        runs.or(searches)
      end
    end

    def limited_records(scope, key, total: nil)
      total ||= scope.except(:includes, :preload, :eager_load, :order, :limit, :offset).count
      records = scope.limit(DETAIL_LIMITS.fetch(key)).to_a
      omitted_counts[key] = [ total - records.size, 0 ].max
      records
    end

    def reporting_state(total, reported)
      return "not_reported" if reported.zero?
      return "complete" if reported == total

      "partial"
    end

    def combined_state(states)
      return "complete" if states.all? { |state| state == "complete" }
      return "not_reported" if states.all? { |state| state == "not_reported" }

      "partial"
    end

    def cost_state(statuses, snapshot_count, ledger_count, amounts)
      return "not_reported" if ledger_count.zero? || snapshot_count.zero?
      return "not_reported" if statuses.fetch("not_reported", 0) == snapshot_count
      if amounts.empty?
        return "partial" if statuses.fetch("partial", 0).positive?
        return "unavailable" if statuses.fetch("unavailable", 0).positive?

        return "not_reported"
      end
      return "complete" if snapshot_count == ledger_count && statuses.fetch("complete", 0) == snapshot_count

      "partial"
    end

    def pending_draft?
      (email_drafts + intercom_drafts).any? { |draft| !draft.sent? }
    end

    def task_status_count(status)
      @task_status_counts.fetch(status, 0)
    end

    def task_count
      @task_status_counts.values.sum
    end

    def active_task_count
      %w[pending ready in_progress blocked review_requested].sum { |status| task_status_count(status) }
    end

    def parse_time(value)
      Time.iso8601(value) if value.present?
    rescue ArgumentError
      nil
    end
end
