class AccountDossier
  LIMITS = {
    contacts: 30,
    identities: 40,
    facts: 60,
    cases: 12,
    memories: 60,
    tasks: 20,
    interventions: 20,
    decisions: 20,
    issues: 8
  }.freeze

  FactGroup = Data.define(:key, :label, :items, :effective, :conflicted)
  MemoryItem = Data.define(:record, :state, :effective, :replaced_by)
  MemoryGroup = Data.define(:key, :label, :items, :effective, :conflicted)
  NextAction = Data.define(:label, :detail, :record)

  attr_reader :workspace, :account, :membership, :now

  def initialize(workspace:, account:, membership:, now: Time.current)
    @workspace = workspace
    @account = workspace.accounts.find(account.id)
    @membership = workspace.memberships.find(membership.id)
    @now = now
    @truncated = {}
  end

  def contacts
    @contacts ||= bounded(
      contact_scope
      .includes(source_merges: :target, source_identities: :source_identity_keys)
      .order(:name, :id)
      .limit(LIMITS.fetch(:contacts) + 1)
      .to_a,
      :contacts
    )
  end

  def identities
    @identities ||= begin
      records = identity_scope
        .includes(
          :source_identity_keys,
          identity_match_candidates: [ { account: { source_merges: :target } }, { contact: { source_merges: :target } } ]
        )
        .order(created_at: :desc, id: :desc)
        .limit(LIMITS.fetch(:identities) + 1)
        .to_a
      bounded(records, :identities)
    end
  end

  def identity!(id)
    identity_scope.find(id)
  end

  def fact_groups
    @fact_groups ||= begin
      limit = LIMITS.fetch(:facts)
      history = workspace.account_health_inputs
        .where(workspace_id: workspace.id, account_id: account_ids)
        .includes(:corrects_input)
        .order(observed_at: :desc, id: :desc)
        .limit(limit + 1)
        .to_a
      effective = AccountHealthInput.effective_for(
        workspace:, account_ids:, at: now, one_per_key: true
      ).includes(:corrects_input).to_a
      visible = visible_fact_history(history, effective, limit)
      effective_by_key = effective.index_by(&:input_key)
      conflicted_keys = AccountHealthInput.effective_for(
        workspace:, account_ids:, at: now
      ).reorder(nil)
        .group(:input_key)
        .having("COUNT(DISTINCT (account_health_inputs.numeric_value, account_health_inputs.date_value)) > 1")
        .pluck(:input_key)
        .to_set

      @truncated[:facts] = history.length > limit
      visible.group_by(&:input_key)
        .map do |key, items|
          FactGroup.new(
            key:, label: key.humanize, items:, effective: effective_by_key[key],
            conflicted: conflicted_keys.include?(key)
          )
        end
        .sort_by(&:label)
    end
  end

  def memory_groups
    @memory_groups ||= memory_records
      .group_by { |record| [ record.scope_kind, record.topic ] }
      .map do |key, records|
        ordered = records.sort_by { |record| memory_sort_key(record) }
        effective = ordered.find { |record| memory_state(record) == "current" }
        replacements = records.index_by(&:supersedes_memory_record_id)
        items = ordered.map do |record|
          MemoryItem.new(
            record:, state: memory_state(record), effective: record == effective, replaced_by: replacements[record.id]
          )
        end
        current_digests = items.select { |item| item.state == "current" }.map { |item| item.record.content_digest }.uniq
        MemoryGroup.new(
          key:, label: key.last, items:, effective:,
          conflicted: current_digests.many?
        )
      end
      .sort_by { |group| [ group.conflicted ? 0 : 1, group.label.downcase ] }
  end

  def recent_cases
    @recent_cases ||= bounded(
      case_scope
      .includes(:tags, conversation: :contact)
      .order(Arel.sql("COALESCE(conversations.last_message_at, conversations.started_at) DESC"), id: :desc)
      .limit(LIMITS.fetch(:cases) + 1)
      .to_a,
      :cases
    )
  end

  def recurring_issues
    @recurring_issues ||= bounded(
      workspace.tags
      .joins(:support_case_taggings)
      .where(support_case_taggings: { support_case_id: case_scope.reselect(:id) })
      .group("tags.id")
      .having("COUNT(support_case_taggings.id) > 1")
      .select("tags.*, COUNT(support_case_taggings.id) AS dossier_case_count")
      .order(Arel.sql("COUNT(support_case_taggings.id) DESC"), "tags.name ASC")
      .limit(LIMITS.fetch(:issues) + 1)
      .to_a,
      :issues
    )
  end

  def assessment
    @assessment ||= workspace.account_health_assessments
      .where(account_id: account_ids)
      .includes(:signals)
      .order(calculated_at: :desc, id: :desc)
      .first
  end

  def tasks
    @tasks ||= bounded(
      task_scope
      .includes(:support_case, :account, :assigned_agent_profile, :owner_user, :current_event)
      .order(Arel.sql("CASE crew_tasks.status WHEN 'blocked' THEN 0 WHEN 'review_requested' THEN 1 WHEN 'failed' THEN 2 WHEN 'in_progress' THEN 3 ELSE 4 END"),
        created_at: :desc, id: :desc)
      .limit(LIMITS.fetch(:tasks) + 1)
      .to_a,
      :tasks
    )
  end

  def interventions
    @interventions ||= bounded(
      workspace.customer_success_interventions
        .where(account_id: account_ids)
        .includes(:outcome_review, accountable_membership: :user)
        .order(proposed_at: :desc, id: :desc)
        .limit(LIMITS.fetch(:interventions) + 1)
        .to_a,
      :interventions
    )
  end

  def decisions
    @decisions ||= begin
      records = workspace.crew_artifacts
        .where(crew_task_id: tasks.map(&:id), artifact_kind: %w[intervention_plan success_review])
        .select("DISTINCT ON (crew_task_id, artifact_kind) crew_artifacts.*")
        .order(:crew_task_id, :artifact_kind, version_number: :desc, id: :desc)
        .to_a
        .sort_by { |artifact| [ artifact.created_at, artifact.id ] }
        .reverse
      bounded(records, :decisions)
    end
  end

  def conflict_count
    identities.count(&:ambiguous?) + fact_groups.count(&:conflicted) + memory_groups.count(&:conflicted)
  end

  def memory_visible?
    membership.can_inspect_memory?
  end

  def truncated?(kind)
    @truncated.fetch(kind, false)
  end

  def next_action
    @next_action ||= begin
      intervention = interventions.find { |candidate| candidate.proposed? || candidate.approved? || candidate.completed? }
      if intervention
        label = if intervention.proposed?
          "Approve or abandon the proposed intervention"
        elsif intervention.approved?
          "Complete the approved intervention"
        else
          "Review the observed outcome"
        end
        NextAction.new(
          label:, detail: "#{intervention.status.humanize} · accountable to #{intervention.accountable_membership.user.email_address}",
          record: intervention
        )
      elsif (investigation = workspace.account_risk_investigations
        .where(account_id: account_ids, status: %w[detected investigating])
        .order(opened_at: :desc, id: :desc)
        .first)
        NextAction.new(
          label: investigation.detected? ? "Start the risk review" : "Complete the risk review",
          detail: "#{investigation.trigger_kind.humanize} · human-owned Customer Success work",
          record: investigation
        )
      elsif (task = tasks.find { |candidate| !candidate.completed? && !candidate.canceled? })
        NextAction.new(
          label: task.title,
          detail: "#{task.status.humanize} · owned by #{task.owner_user.email_address}",
          record: task
        )
      elsif (support_case = recent_cases.find { |candidate| !candidate.status_closed? })
        NextAction.new(
          label: "Continue #{support_case.conversation.subject.presence || "the open case"}",
          detail: "#{support_case.status.humanize} · #{support_case.priority} priority",
          record: support_case
        )
      else
        NextAction.new(label: "No open action", detail: "No unresolved case, task, or risk review is recorded.", record: nil)
      end
    end
  end

  private
    def visible_fact_history(history, effective, limit)
      visible = history.first(limit).dup
      effective_ids = effective.map(&:id).to_set
      effective.each do |input|
        next if visible.any? { |candidate| candidate.id == input.id }

        replacement_index = visible.rindex { |candidate| !effective_ids.include?(candidate.id) }
        visible.delete_at(replacement_index) if replacement_index
        visible << input if replacement_index
      end
      visible.sort_by { |input| [ -input.observed_at.to_f, -input.id ] }
    end

    def account_ids
      @account_ids ||= [ account.id ] + workspace.account_merges.active.where(target_id: account.id).pluck(:source_id)
    end

    def contact_scope
      @contact_scope ||= workspace.contacts.where(account_id: account_ids)
    end

    def contact_ids
      contact_scope.reselect(:id)
    end

    def case_scope
      @case_scope ||= workspace.support_cases
        .joins(:conversation)
        .where(conversations: { contact_id: contact_ids })
    end

    def identity_scope
      candidate_ids = workspace.identity_match_candidates
        .where(account_id: account_ids)
        .or(workspace.identity_match_candidates.where(contact_id: contact_ids))
        .select(:source_identity_id)
      workspace.source_identities
        .where(account_id: account_ids)
        .or(workspace.source_identities.where(contact_id: contact_ids))
        .or(workspace.source_identities.where(id: candidate_ids))
    end

    def task_scope
      workspace.crew_tasks
        .where(account_id: account_ids)
        .or(workspace.crew_tasks.where(support_case_id: case_scope.reselect(:id)))
    end

    def memory_records
      return [] unless memory_visible?

      @memory_records ||= begin
        relation = MemoryGovernance.accessible_records(workspace, membership)
        scoped = relation.where(account_id: account_ids)
          .or(relation.where(contact_id: contact_ids))
          .or(relation.where(support_case_id: case_scope.reselect(:id)))
        records = scoped
          .includes(:memory_tombstone, :supersedes_memory_record, :source_user)
          .order(observed_at: :desc, id: :desc)
          .limit(LIMITS.fetch(:memories) + 1)
          .to_a
        records = bounded(records, :memories)
        @superseded_memory_ids = workspace.memory_records
          .where(supersedes_memory_record_id: records.map(&:id))
          .pluck(:supersedes_memory_record_id)
          .to_set
        records
      end
    end

    def memory_state(record)
      return "deleted" if record.memory_tombstone
      return "superseded" if @superseded_memory_ids.include?(record.id)
      return "stale" unless record.eligible_at?(now)

      "current"
    end

    def memory_sort_key(record)
      state_rank = { "current" => 0, "stale" => 1, "superseded" => 2, "deleted" => 3 }.fetch(memory_state(record))
      authority_rank = MemoryRecord::AUTHORITIES.reverse.index(record.authority)
      [ state_rank, authority_rank, -record.observed_at.to_f, -record.id ]
    end

    def bounded(records, kind)
      limit = LIMITS.fetch(kind)
      @truncated[kind] = records.length > limit
      records.first(limit)
    end
end
