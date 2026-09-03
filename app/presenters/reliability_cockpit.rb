class ReliabilityCockpit
  CONNECTOR_FRESH_FOR = 24.hours
  INDEX_BACKLOG_LIMIT = 5.minutes
  OPERATIONAL_CHECK_FRESH_FOR = 30.days
  DETAIL_LIMIT = 20
  STATUS_PRIORITY = {
    "healthy" => 0,
    "not_configured" => 1,
    "attention" => 2,
    "unknown" => 3,
    "blocked" => 4
  }.freeze

  Item = Data.define(:key, :title, :status, :summary, :detail, :occurred_at, :record, :action)
  Group = Data.define(:key, :title, :status, :summary, :items)

  attr_reader :groups, :overall_status

  def self.build(workspace:, membership:, now: Time.current)
    new(workspace:, membership:, now:).tap(&:build)
  end

  def initialize(workspace:, membership:, now:)
    @workspace = workspace
    @membership = workspace.memberships.find(membership.id)
    raise Current::RoleAccessDenied unless @membership.can_manage_work?

    @now = now
  end

  def build
    @groups = [
      connector_group,
      queue_group,
      execution_group,
      send_group,
      memory_group,
      data_group
    ]
    @overall_status = strongest_status(@groups.map(&:status))
    self
  end

  def status_counts
    @groups.map(&:status).tally
  end

  private
    def connector_group
      items = email_connector_items + intercom_connector_items
      statuses = email_connector_statuses + intercom_connector_statuses
      status = statuses.empty? ? "not_configured" : strongest_status(statuses)
      retryable = email_connector_metrics[:retry_counts].values.sum +
        intercom_connector_metrics[:retry_counts].values.sum
      terminal = email_connector_metrics[:terminal_counts].values.sum +
        intercom_connector_metrics[:terminal_counts].values.sum
      replayed = email_connector_metrics[:replayed_count] + intercom_connector_metrics[:replayed_count]
      summary = if items.empty?
        "No inbound connector is configured."
      else
        "#{counted(retryable, 'retryable delivery', 'retryable deliveries')}, " \
          "#{counted(terminal, 'terminal delivery', 'terminal deliveries')}, and " \
          "#{counted(replayed, 'replayed inbound delivery', 'replayed inbound deliveries')}."
      end
      Group.new(key: "connectors", title: "Connectors and intake", status:, summary:, items:)
    end

    def email_connector_statuses
      metrics = email_connector_metrics
      @workspace.shared_email_inboxes.find_each.map do |inbox|
        connector_status(
          active: inbox.active?, ready: inbox.webhook_ready?, last_seen: metrics[:latest][inbox.id],
          retry_count: metrics[:retry_counts].fetch(inbox.id, 0),
          terminal_count: metrics[:terminal_counts].fetch(inbox.id, 0),
          error_code: nil
        ).first
      end
    end

    def intercom_connector_statuses
      metrics = intercom_connector_metrics
      @workspace.intercom_connections.find_each.map do |connection|
        connector_status(
          active: connection.active?, ready: connection.ready?, last_seen: connection.last_reconciled_at,
          retry_count: metrics[:retry_counts].fetch(connection.id, 0),
          terminal_count: metrics[:terminal_counts].fetch(connection.id, 0),
          error_code: connection.last_error_code
        ).first
      end
    end

    def email_connector_items
      inboxes = @workspace.shared_email_inboxes.order(:name, :id).limit(DETAIL_LIMIT).to_a
      metrics = email_connector_metrics
      inboxes.map do |inbox|
        retry_count = metrics[:retry_counts].fetch(inbox.id, 0)
        terminal_count = metrics[:terminal_counts].fetch(inbox.id, 0)
        last_seen = metrics[:latest][inbox.id]
        status, summary = connector_status(
          active: inbox.active?, ready: inbox.webhook_ready?, last_seen:,
          retry_count:, terminal_count:, error_code: nil
        )
        Item.new(
          key: "email-#{inbox.id}", title: "Email · #{inbox.name}", status:, summary:,
          detail: last_seen ? "Latest signed delivery received." : "No signed delivery evidence yet.",
          occurred_at: last_seen, record: inbox,
          action: @membership.can_configure_integrations? ? "manage_email" : nil
        )
      end
    end

    def intercom_connector_items
      connections = @workspace.intercom_connections.order(:name, :id).limit(DETAIL_LIMIT).to_a
      metrics = intercom_connector_metrics
      connections.map do |connection|
        retry_count = metrics[:retry_counts].fetch(connection.id, 0)
        terminal_count = metrics[:terminal_counts].fetch(connection.id, 0)
        status, summary = connector_status(
          active: connection.active?, ready: connection.ready?, last_seen: connection.last_reconciled_at,
          retry_count:, terminal_count:, error_code: connection.last_error_code
        )
        cursor = connection.reconciliation_cursor.present? ? "Cursor saved." : "No reconciliation cursor saved."
        Item.new(
          key: "intercom-#{connection.id}", title: "Intercom · #{connection.name}", status:, summary:,
          detail: cursor, occurred_at: connection.last_reconciled_at, record: connection,
          action: @membership.can_configure_integrations? ? "manage_intercom" : nil
        )
      end
    end

    def email_connector_metrics
      @email_connector_metrics ||= {
        latest: @workspace.inbound_email_deliveries.group(:shared_email_inbox_id).maximum(:received_at),
        retry_counts: @workspace.inbound_email_deliveries.outstanding.group(:shared_email_inbox_id).count,
        terminal_counts: terminal_email_deliveries.group(:shared_email_inbox_id).count,
        replayed_count: @workspace.inbound_email_deliveries.processed.where("attempt_count > 0").count
      }
    end

    def intercom_connector_metrics
      @intercom_connector_metrics ||= {
        retry_counts: @workspace.intercom_webhook_deliveries.retryable.group(:intercom_connection_id).count,
        terminal_counts: terminal_intercom_deliveries.group(:intercom_connection_id).count,
        replayed_count: @workspace.intercom_webhook_deliveries.processed.where("attempt_count > 1").count
      }
    end

    def connector_status(active:, ready:, last_seen:, retry_count:, terminal_count:, error_code:)
      return [ "not_configured", "Connector is paused." ] unless active
      return [ "blocked", "Credentials or webhook signing are not ready." ] unless ready
      return [ "blocked", "Manual review: #{counted(terminal_count, 'delivery', 'deliveries')}." ] if terminal_count.positive?
      return [ "blocked", "Reconciliation failed: #{error_code.humanize}." ] if error_code.present?
      return [ "attention", "Safe retries: #{counted(retry_count, 'delivery', 'deliveries')}." ] if retry_count.positive?
      return [ "unknown", "No freshness evidence has been recorded." ] unless last_seen
      return [ "attention", "Freshness evidence is older than 24 hours." ] if last_seen < @now - CONNECTOR_FRESH_FOR

      [ "healthy", "Ready with fresh delivery or reconciliation evidence." ]
    end

    def terminal_email_deliveries
      outstanding = @workspace.inbound_email_deliveries.outstanding.select(:id)
      @workspace.inbound_email_deliveries.where(status: %w[received failed]).where.not(id: outstanding)
    end

    def terminal_intercom_deliveries
      retryable = @workspace.intercom_webhook_deliveries.retryable.select(:id)
      @workspace.intercom_webhook_deliveries.where(status: %w[received failed]).where.not(id: retryable)
    end

    def queue_group
      status = "not_configured"
      summary = "Workspace-specific queue evidence is unavailable because the queue is shared."
      item = Item.new(
        key: "solid-queue", title: "Solid Queue", status:, summary:,
        detail: "Shared queue state is intentionally excluded from Workspace health.",
        occurred_at: nil, record: nil, action: nil
      )
      Group.new(key: "queue", title: "Job queue", status:, summary:, items: [ item ])
    end

    def execution_group
      installations = runtime_installations_for_detail
      runtime_items = installations.map { |installation| runtime_item(installation) }
      unconfirmed = @workspace.execution_runs.where(status: :admitting).count
      retryable = @workspace.execution_runs.where(status: :failed, retryable: true).count
      terminal = @workspace.execution_runs.terminal.count
      run_items = execution_run_items
      items = runtime_items + run_items
      statuses = [ runtime_group_status, execution_run_group_status ].compact
      status = statuses.empty? ? "not_configured" : strongest_status(statuses)
      summary = "#{counted(unconfirmed, 'unconfirmed admission')}, #{counted(retryable, 'retryable failure')}, and " \
        "#{counted(terminal, 'terminal run')}."
      Group.new(key: "execution", title: "Runner and execution", status:, summary:, items:)
    end

    def runtime_item(installation)
      status, summary = runtime_status(installation)
      Item.new(
        key: "runtime-#{installation.id}", title: "Runtime · #{installation.adapter_key.humanize}",
        status:, summary:, detail: installation.executable_version, occurred_at: installation.checked_at,
        record: installation, action: @membership.can_configure_agents? ? "manage_runtime" : nil
      )
    end

    def runtime_status(installation)
      if installation.compatibility_status == "incompatible" || installation.health_status != "available"
        [ "blocked", "#{installation.health_status.humanize}; #{installation.compatibility_status.humanize}." ]
      elsif installation.compatibility_status == "unknown"
        [ "unknown", "Runtime compatibility is unknown." ]
      elsif installation.compatibility_status == "warning"
        [ "attention", installation.incompatibility_reason.presence || "Runtime compatibility needs review." ]
      elsif !installation.approved?
        [ "not_configured", "Detected but not approved for work." ]
      elsif installation.checked_at < @now - CONNECTOR_FRESH_FOR
        [ "attention", "Runtime evidence is older than 24 hours." ]
      else
        [ "healthy", "Approved, available, and compatible." ]
      end
    end

    def runtime_group_status
      installations = @workspace.runtime_installations
      return unless installations.exists?
      return "blocked" if installations.where("health_status <> 'available' OR compatibility_status = 'incompatible'").exists?
      return "unknown" if installations.where(compatibility_status: "unknown").exists?
      return "attention" if installations.where(compatibility_status: "warning").exists? ||
        installations.where("checked_at < ?", @now - CONNECTOR_FRESH_FOR).exists?
      return "not_configured" if installations.where(approved: false).exists?

      "healthy"
    end

    def runtime_installations_for_detail
      installations = @workspace.runtime_installations.ordered
      issue_ids = installations.where(
        "health_status <> 'available' OR compatibility_status IN ('warning', 'incompatible', 'unknown') OR " \
          "approved = FALSE OR checked_at < ?", @now - CONNECTOR_FRESH_FOR
      ).limit(DETAIL_LIMIT).pluck(:id)
      issues = @workspace.runtime_installations.where(id: issue_ids).index_by(&:id)
      selected = issue_ids.filter_map { |id| issues[id] }
      return selected if selected.size == DETAIL_LIMIT

      selected + installations.where.not(id: issue_ids).limit(DETAIL_LIMIT - selected.size).to_a
    end

    def execution_run_items
      runs = @workspace.execution_runs
        .where(status: %w[admitting failed timed_out policy_denied])
        .includes(crew_task: [ :support_case, :account ])
        .order(Arel.sql(<<~SQL.squish), :created_at, :id).limit(DETAIL_LIMIT)
          CASE
            WHEN status IN ('timed_out', 'policy_denied') OR (status = 'failed' AND retryable = FALSE) THEN 0
            WHEN status = 'admitting' THEN 1
            ELSE 2
          END
        SQL
        .to_a
      retryable_runs = runs.select { |run| run.failed? && run.retryable? }
      retryable_task_ids = retryable_runs.map(&:crew_task_id).uniq
      active_task_ids = if retryable_task_ids.empty?
        []
      else
        @workspace.execution_runs.active.where(crew_task_id: retryable_task_ids).distinct.pluck(:crew_task_id)
      end

      runs.map do |run|
        if run.admitting?
          Item.new(
            key: "run-#{run.id}", title: "Unconfirmed run ##{run.id}", status: "unknown",
            summary: run.last_admission_error&.humanize || "Runner admission has no definite result.",
            detail: run.crew_task.title, occurred_at: run.admission_attempted_at || run.created_at,
            record: run, action: "reconcile_run"
          )
        elsif run.failed? && run.retryable?
          eligible = run.crew_task.in_progress? && !active_task_ids.include?(run.crew_task_id)
          Item.new(
            key: "run-#{run.id}", title: "Retryable run ##{run.id}", status: "attention",
            summary: run.failure_code.to_s.humanize.presence || "Definite failure can be retried.",
            detail: run.crew_task.title, occurred_at: run.finished_at,
            record: run, action: eligible ? "retry_run" : nil
          )
        else
          Item.new(
            key: "run-#{run.id}", title: "Terminal run ##{run.id}", status: "blocked",
            summary: run.failure_code.to_s.humanize.presence || "Run ended without a safe retry path.",
            detail: run.crew_task.title, occurred_at: run.finished_at,
            record: run, action: nil
          )
        end
      end
    end

    def execution_run_group_status
      runs = @workspace.execution_runs
      return "blocked" if runs.where(status: %w[timed_out policy_denied]).exists? ||
        runs.where(status: :failed, retryable: false).exists?
      return "unknown" if runs.where(status: :admitting).exists?

      "attention" if runs.where(status: :failed, retryable: true).exists?
    end

    def send_group
      email_scope = @workspace.outbound_email_deliveries.where(status: %w[sending unknown])
      intercom_scope = @workspace.intercom_outbound_deliveries.where(status: %w[sending unknown])
      total = email_scope.count + intercom_scope.count
      email = email_scope.includes(conversation: :support_case)
        .order(started_at: :asc, id: :asc).limit(DETAIL_LIMIT).to_a
      intercom = intercom_scope.includes(conversation: :support_case)
        .order(started_at: :asc, id: :asc).limit(DETAIL_LIMIT).to_a
      items = email.map { |delivery| unknown_send_item(delivery, "Email", "review_email_send") } +
        intercom.map { |delivery| unknown_send_item(delivery, "Intercom", "review_intercom_send") }
      status = items.empty? ? "healthy" : "unknown"
      summary = total.zero? ? "No customer send has an unknown effect." :
        "Human investigation required for #{counted(total, 'frozen send attempt')}."
      Group.new(key: "sends", title: "Customer sends", status:, summary:, items: items.first(DETAIL_LIMIT))
    end

    def unknown_send_item(delivery, channel, action)
      Item.new(
        key: "#{channel.downcase}-send-#{delivery.id}", title: "#{channel} attempt ##{delivery.id}",
        status: "unknown", summary: "Do not resend. Check the external system first.",
        detail: delivery.failure_code&.humanize || "Attempt may still be active.",
        occurred_at: delivery.started_at, record: delivery, action:
      )
    end

    def memory_group
      entries = @workspace.memory_index_entries
      failed = entries.where(status: :failed).count
      unknown = entries.where(status: :unknown).count
      backlog = entries.where(status: %w[pending indexing queued]).count
      stale_backlog = entries.where(status: %w[pending indexing queued])
        .where("COALESCE(last_attempted_at, created_at) < ?", @now - INDEX_BACKLOG_LIMIT).count
      status = if failed.positive?
        "blocked"
      elsif unknown.positive?
        "unknown"
      elsif stale_backlog.positive? || backlog.positive?
        "attention"
      elsif entries.exists?
        "healthy"
      else
        "not_configured"
      end
      summary = "#{counted(backlog, 'queued or active index operation')}, " \
        "#{counted(failed, 'failed index operation')}, and #{counted(unknown, 'unknown index operation')}."
      detail_items = entries.where(status: %w[failed unknown]).includes(:memory_record)
        .order(Arel.sql("COALESCE(last_attempted_at, created_at) ASC"), :id).limit(DETAIL_LIMIT).map do |entry|
        Item.new(
          key: "memory-#{entry.id}", title: entry.memory_record.topic,
          status: entry.failed? ? "blocked" : "unknown",
          summary: entry.failure_code.to_s.humanize.presence || "External index result is unknown.",
          detail: "PostgreSQL Memory remains authoritative.",
          occurred_at: entry.last_attempted_at || entry.created_at, record: entry, action: nil
        )
      end
      overview = Item.new(
        key: "memory-index", title: "Memory index", status:, summary:,
        detail: "Backlog becomes stale after five minutes.", occurred_at: entries.maximum(:last_attempted_at),
        record: nil, action: (failed + unknown).positive? ? "reconstruct_memory" : nil
      )
      Group.new(key: "memory", title: "Memory index", status:, summary:, items: [ overview, *detail_items ])
    end

    def data_group
      items = [ retention_item, export_item, *operational_check_items ]
      Group.new(
        key: "data", title: "Data protection", status: strongest_status(items.map(&:status)),
        summary: "Retention, archive, backup, restore, and upgrade evidence stay separate.", items:
      )
    end

    def retention_item
      policy = @workspace.workspace_data_policy
      latest = @workspace.workspace_content_expiry_runs.order(created_at: :desc, id: :desc).first
      status, summary = if policy.nil? || (policy.content_retention_days.nil? && policy.audit_retention_days.nil?)
        [ "not_configured", "No automatic content or audit expiry is configured." ]
      elsif latest&.failed? || policy.audit_expiry_status == "failed"
        [ "blocked", "The latest retention operation failed." ]
      elsif latest&.status.in?(%w[pending running]) || policy.audit_expiry_status.in?(%w[pending running])
        [ "attention", "A retention operation is pending or running." ]
      else
        [ "healthy", "Configured retention has no recorded failure." ]
      end
      occurred_at = [ latest&.completed_at, policy&.audit_expiry_completed_at ].compact.max
      Item.new(
        key: "retention", title: "Retention", status:, summary:,
        detail: "Content and audit cutoffs are separate.", occurred_at:, record: policy,
        action: @membership.owner? ? "manage_data" : nil
      )
    end

    def export_item
      audit = @workspace.audit_events.where(action: %w[workspace.exported workspace.imported])
        .order(occurred_at: :desc, id: :desc).first
      status = audit ? "healthy" : "unknown"
      summary = audit ? "Latest #{audit.action.delete_prefix('workspace.')} recorded with bounded counts." :
        "No Workspace export or import is recorded."
      Item.new(
        key: "workspace-archive", title: "Workspace archive activity", status:, summary:,
        detail: "Activity is not the same as a verified round trip.", occurred_at: audit&.occurred_at,
        record: audit, action: @membership.owner? ? "manage_data" : nil
      )
    end

    def operational_check_items
      latest = @workspace.operational_checks.where(check_kind: OperationalCheck::CHECK_KINDS)
        .select("DISTINCT ON (check_kind) operational_checks.*")
        .order(Arel.sql("check_kind, checked_at DESC, id DESC"))
        .to_a.index_by(&:check_kind)
      OperationalCheck::CHECK_KINDS.map do |kind|
        check = latest[kind]
        status, summary = operational_check_status(check)
        Item.new(
          key: kind, title: kind.humanize, status:, summary:,
          detail: operational_count_detail(check),
          occurred_at: check&.checked_at, record: check, action: nil
        )
      end
    end

    def operational_count_detail(check)
      return "No copied logs or secrets are stored." unless check

      counts = []
      counts << counted(check.table_count, "table") if check.table_count
      counts << counted(check.record_count, "record") if check.record_count
      counts << counted(check.attachment_count, "attachment") if check.attachment_count
      counts << counted(check.memory_count, "Memory record") if check.memory_count
      counts.any? ? "Verified #{counts.to_sentence}." : "No copied logs or secrets are stored."
    end

    def operational_check_status(check)
      return [ "not_configured", "No check evidence has been recorded." ] unless check
      return [ "blocked", "Check failed: #{check.result_code.humanize}." ] if check.result == "failed"
      return [ "unknown", "Check was unavailable: #{check.result_code.humanize}." ] if check.result == "unavailable"
      return [ "attention", "Last passing check is older than 30 days." ] if
        check.checked_at < @now - OPERATIONAL_CHECK_FRESH_FOR

      [ "healthy", "Passed with evidence digest #{check.evidence_digest.first(12)}…." ]
    end

    def strongest_status(statuses)
      statuses.max_by { |status| STATUS_PRIORITY.fetch(status) }
    end

    def counted(count, singular, plural = nil)
      "#{count} #{count == 1 ? singular : plural || "#{singular}s"}"
    end
end
