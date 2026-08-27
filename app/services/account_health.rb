class AccountHealth
  Signal = Data.define(
    :signal_key, :value_kind, :numeric_value, :date_value, :weight, :risk_points,
    :source_kind, :source_locator, :range_starts_at, :range_ends_at,
    :evidence_refs, :evidence_omitted_count
  ) do
    def initialize(evidence_refs: [], evidence_omitted_count: 0, **attributes)
      super(evidence_refs:, evidence_omitted_count:, **attributes)
    end
  end
  MATERIAL_SCORE_CHANGE = 10
  RENEWAL_WINDOW_DAYS = 90
  SUPPORT_WINDOW = 90.days
  MAX_EVIDENCE_REFS = 100

  def self.recalculate!(workspace:, account:, trigger_kind:, membership: nil, at: Time.current)
    new(workspace:, membership:).recalculate!(account:, trigger_kind:, at:)
  end

  def self.recalculate_due!(workspace:, at: Time.current)
    workspace.accounts.order(:id).map do |account|
      renewal = latest_input(account, "renewal_on", at:)&.date_value
      trigger = renewal && renewal.between?(at.to_date, at.to_date + RENEWAL_WINDOW_DAYS) ? "renewal_window" : "schedule"
      recalculate!(workspace:, account:, trigger_kind: trigger, at:)
    end
  end

  def self.latest_input(account, key, at: Time.current)
    account.health_inputs.where(input_key: key).where(observed_at: ..at)
      .where("valid_from IS NULL OR valid_from <= ?", at)
      .where("valid_until IS NULL OR valid_until >= ?", at)
      .order(observed_at: :desc, id: :desc).first
  end

  def initialize(workspace:, membership: nil)
    @workspace = workspace
    @membership = membership && workspace.memberships.find(membership.id)
  end

  def recalculate!(account:, trigger_kind:, at:)
    account = @workspace.accounts.find(account.id)
    raise ArgumentError, "invalid health trigger" unless AccountHealthAssessment::TRIGGER_KINDS.include?(trigger_kind.to_s)

    AccountHealthAssessment.transaction do
      lock_account!(account)
      @calculated_at = at
      prior = account.health_assessments.first
      scorecard_version = HealthScorecardDesigner.install_default!(workspace: @workspace).current_version
      signals = HealthScorecardDefinition.apply(
        signals: build_signals(account, at), definition: scorecard_version.definition, calculated_at: at
      )
      score = [ 100 - signals.sum(&:risk_points), 0 ].max
      level = score >= scorecard_version.definition.fetch("healthy_min") ? "healthy" :
        score >= scorecard_version.definition.fetch("watch_min") ? "watch" : "at_risk"
      material = prior.present? && ((prior.score - score).abs >= MATERIAL_SCORE_CHANGE || prior.risk_level != level)
      renewal = latest(account, "renewal_on")&.date_value
      assessment = account.health_assessments.create!(
        workspace: @workspace, previous_assessment: prior, score:, risk_level: level,
        health_scorecard_version: scorecard_version,
        trigger_kind: trigger_kind.to_s, material_change: material, renewal_on: renewal, calculated_at: at
      )
      signals.each { |signal| assessment.signals.create!(workspace: @workspace, **signal.to_h) }
      audit!("account.health_recalculated", assessment, trigger_kind: trigger_kind.to_s, risk_level: level)
      open_investigation!(assessment, trigger_kind, material, renewal, at)
      assessment
    end
  end

  private
    def build_signals(account, at)
      conversations = @workspace.conversations.where(contact_id: account.contacts.select(:id))
      cases = @workspace.support_cases.where(conversation_id: conversations.select(:id))
      open_cases = cases.where.not(status: %w[resolved closed])
      open_count = open_cases.count
      breached_slas = @workspace.case_slas.where(support_case_id: cases.select(:id))
        .where("first_response_status = 'breached' OR resolution_status = 'breached'")
      breach_count = breached_slas.count
      notes_since = at - 90.days
      notes = @workspace.case_notes.where(support_case_id: cases.select(:id), created_at: notes_since..at)
      note_count = notes.count
      inbound = @workspace.conversation_messages.inbound.where(conversation_id: conversations.select(:id), occurred_at: ..at)
      last_inbound = inbound.maximum(:occurred_at)
      inactivity_days = last_inbound ? [ ((at - last_inbound) / 1.day).floor, 0 ].max : 365
      support_since = at - SUPPORT_WINDOW
      reopened = @workspace.support_case_status_changes.where(support_case_id: cases.select(:id), occurred_at: support_since..at,
        from_status: %w[resolved closed], to_status: "investigating")
      repeated_taggings = repeated_human_taggings(cases, support_since, at)
      resolved_changes = @workspace.support_case_status_changes.where(
        support_case_id: cases.select(:id), occurred_at: support_since..at, to_status: "resolved"
      )
      resolved_case_ids = resolved_changes.reorder(:support_case_id).distinct.pluck(:support_case_id)
      complete_artifacts = @workspace.crew_artifacts.joins(:crew_task).where(
        crew_tasks: { support_case_id: resolved_case_ids }, contract_result_state: "complete",
        contract_evaluated_at: ..at
      )
      proofed_case_ids = complete_artifacts.reorder("crew_tasks.support_case_id").distinct.pluck("crew_tasks.support_case_id")
      unproofed_case_ids = resolved_case_ids - proofed_case_ids

      signals = [
        number_signal("open_cases", open_count,
          "support_cases", "account://#{account.id}/cases", nil, at,
          references_for("support_case", open_cases)),
        number_signal("sla_breaches", breach_count,
          "sla", "account://#{account.id}/slas", nil, at,
          references_for("case_sla", breached_slas)),
        number_signal("internal_notes_90d", note_count,
          "case_notes", "account://#{account.id}/notes", notes_since, at,
          references_for("case_note", notes)),
        number_signal("customer_inactivity_days", inactivity_days,
          "conversation", "account://#{account.id}/conversations", last_inbound, at,
          references_for("conversation_message", inbound.order(occurred_at: :desc, id: :desc).limit(1))),
        number_signal("recurring_issue_tags_90d", repeated_taggings.count,
          "case_tags", "account://#{account.id}/support-evidence/recurring-tags", support_since, at,
          tagging_references(repeated_taggings)),
        number_signal("reopened_cases_90d", reopened.count,
          "case_status", "account://#{account.id}/support-evidence/reopened", support_since, at,
          references_for("support_case_status_change", reopened)),
        number_signal("resolutions_without_proof_90d", unproofed_case_ids.size,
          "resolution_contract", "account://#{account.id}/support-evidence/resolution-proof", support_since, at,
          references_from_ids("support_case", unproofed_case_ids)),
        number_signal("proofed_resolutions_90d", proofed_case_ids.size,
          "resolution_contract", "account://#{account.id}/support-evidence/resolution-proof", support_since, at,
          resolution_references(proofed_case_ids, complete_artifacts))
      ]
      if (renewal = latest(account, "renewal_on"))
        signals << date_signal("renewal_on", renewal.date_value, renewal, at)
      end
      active = latest(account, "active_users")
      licensed = latest(account, "licensed_seats")
      if active&.numeric_value && licensed&.numeric_value&.positive?
        utilization = ((active.numeric_value / licensed.numeric_value) * 100).round(2)
        signals << number_signal("seat_utilization_percent", utilization,
          "account_input", active.source_locator, [ active.observed_at, licensed.observed_at ].min, at,
          references_from_ids("account_health_input", [ active.id, licensed.id ]))
      end
      if (contract = latest(account, "contract_value"))
        signals << number_signal("contract_value", contract.numeric_value,
          "account_input", contract.source_locator, contract.observed_at, at,
          references_from_ids("account_health_input", [ contract.id ]))
      end
      signals
    end

    def number_signal(key, value, source_kind, locator, starts_at, ends_at, evidence = [ [], 0 ])
      Signal.new(signal_key: key, value_kind: "number", numeric_value: value, date_value: nil,
        weight: 0, risk_points: 0, source_kind:, source_locator: locator,
        range_starts_at: starts_at, range_ends_at: ends_at,
        evidence_refs: evidence.first, evidence_omitted_count: evidence.last)
    end

    def date_signal(key, value, input, at)
      Signal.new(signal_key: key, value_kind: "date", numeric_value: nil, date_value: value,
        weight: 0, risk_points: 0, source_kind: "account_input", source_locator: input.source_locator,
        range_starts_at: input.observed_at, range_ends_at: at,
        evidence_refs: [ { "kind" => "account_health_input", "id" => input.id } ], evidence_omitted_count: 0)
    end

    def latest(account, key)
      self.class.latest_input(account, key, at: @calculated_at)
    end

    def repeated_human_taggings(cases, starts_at, ends_at)
      scope = @workspace.support_case_taggings.where(
        support_case_id: cases.select(:id), source_intercom_connection_id: nil, created_at: starts_at..ends_at
      ).where(<<~SQL.squish)
        EXISTS (
          SELECT 1 FROM audit_events
          WHERE audit_events.workspace_id = support_case_taggings.workspace_id
            AND audit_events.action = 'case.tag_added'
            AND audit_events.actor_id IS NOT NULL
            AND audit_events.subject_type = 'SupportCase'
            AND audit_events.subject_id = support_case_taggings.support_case_id
            AND (audit_events.metadata ->> 'tag_id')::bigint = support_case_taggings.tag_id
            AND audit_events.occurred_at BETWEEN #{AccountHealthInput.connection.quote(starts_at)}
              AND #{AccountHealthInput.connection.quote(ends_at)}
        )
      SQL
      repeated_tag_ids = scope.group(:tag_id).having("COUNT(DISTINCT support_case_id) > 1").select(:tag_id)
      scope.where(tag_id: repeated_tag_ids)
    end

    def references_for(kind, relation)
      count = relation.count
      ids = relation.reorder(:id).limit(MAX_EVIDENCE_REFS).pluck(:id)
      [ ids.map { |id| { "kind" => kind, "id" => id } }, [ count - ids.size, 0 ].max ]
    end

    def references_from_ids(kind, ids)
      unique_ids = ids.uniq
      [ unique_ids.first(MAX_EVIDENCE_REFS).map { |id| { "kind" => kind, "id" => id } },
        [ unique_ids.size - MAX_EVIDENCE_REFS, 0 ].max ]
    end

    def tagging_references(taggings)
      pairs = taggings.reorder(:id).pluck(:support_case_id, :tag_id)
      references = pairs.flat_map do |support_case_id, tag_id|
        [ { "kind" => "support_case", "id" => support_case_id }, { "kind" => "tag", "id" => tag_id } ]
      end.uniq
      [ references.first(MAX_EVIDENCE_REFS), [ references.size - MAX_EVIDENCE_REFS, 0 ].max ]
    end

    def resolution_references(case_ids, artifacts)
      references = case_ids.map { |id| { "kind" => "support_case", "id" => id } }
      references.concat(artifacts.reorder(:id).pluck(:id).map { |id| { "kind" => "crew_artifact", "id" => id } })
      references.uniq!
      [ references.first(MAX_EVIDENCE_REFS), [ references.size - MAX_EVIDENCE_REFS, 0 ].max ]
    end

    def open_investigation!(assessment, trigger, material, renewal, at)
      investigation_trigger = if trigger.to_s == "human_request"
        "human_request"
      elsif renewal&.between?(at.to_date, at.to_date + RENEWAL_WINDOW_DAYS)
        "renewal_window"
      elsif material
        "material_change"
      end
      return unless investigation_trigger
      return if assessment.account.risk_investigations.where(status: %w[detected investigating]).exists?

      investigation = @workspace.account_risk_investigations.create!(
        account: assessment.account, account_health_assessment: assessment,
        status: :detected, trigger_kind: investigation_trigger, opened_at: at
      )
      audit!("account.risk_detected", investigation, trigger_kind: investigation_trigger)
    end

    def lock_account!(account)
      value = Account.connection.quote("account-health:#{@workspace.id}:#{account.id}")
      Account.connection.execute("SELECT pg_advisory_xact_lock(hashtext(#{value}))")
    end

    def audit!(action, subject, metadata)
      AuditEvent.record!(action:, source: @membership ? :web : :job, workspace: @workspace,
        actor: @membership&.user, actor_kind: (@membership ? nil : :system), subject:, metadata:)
    end
end
