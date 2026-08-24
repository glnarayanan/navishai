class AccountHealth
  Signal = Data.define(
    :signal_key, :value_kind, :numeric_value, :date_value, :weight, :risk_points,
    :source_kind, :source_locator, :range_starts_at, :range_ends_at
  )
  MATERIAL_SCORE_CHANGE = 10
  RENEWAL_WINDOW_DAYS = 90

  def self.recalculate!(workspace:, account:, trigger_kind:, membership: nil, at: Time.current)
    new(workspace:, membership:).recalculate!(account:, trigger_kind:, at:)
  end

  def self.recalculate_due!(workspace:, at: Time.current)
    workspace.accounts.order(:id).map do |account|
      renewal = latest_input(account, "renewal_on")&.date_value
      trigger = renewal && renewal.between?(at.to_date, at.to_date + RENEWAL_WINDOW_DAYS) ? "renewal_window" : "schedule"
      recalculate!(workspace:, account:, trigger_kind: trigger, at:)
    end
  end

  def self.latest_input(account, key)
    account.health_inputs.where(input_key: key).order(observed_at: :desc, id: :desc).first
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
      open_count = cases.where.not(status: %w[resolved closed]).count
      breach_count = @workspace.case_slas.where(support_case_id: cases.select(:id))
        .where("first_response_status = 'breached' OR resolution_status = 'breached'").count
      notes_since = at - 90.days
      note_count = @workspace.case_notes.where(support_case_id: cases.select(:id), created_at: notes_since..at).count
      last_inbound = @workspace.conversation_messages.inbound.where(conversation_id: conversations.select(:id)).maximum(:occurred_at)
      inactivity_days = last_inbound ? [ ((at - last_inbound) / 1.day).floor, 0 ].max : 365

      signals = [
        number_signal("open_cases", open_count,
          "support_cases", "account://#{account.id}/cases", nil, at),
        number_signal("sla_breaches", breach_count,
          "sla", "account://#{account.id}/slas", nil, at),
        number_signal("internal_notes_90d", note_count,
          "case_notes", "account://#{account.id}/notes", notes_since, at),
        number_signal("customer_inactivity_days", inactivity_days,
          "conversation", "account://#{account.id}/conversations", last_inbound, at)
      ]
      if (renewal = latest(account, "renewal_on"))
        signals << date_signal("renewal_on", renewal.date_value, renewal, at)
      end
      active = latest(account, "active_users")
      licensed = latest(account, "licensed_seats")
      if active&.numeric_value && licensed&.numeric_value&.positive?
        utilization = ((active.numeric_value / licensed.numeric_value) * 100).round(2)
        signals << number_signal("seat_utilization_percent", utilization,
          "account_input", active.source_locator, [ active.observed_at, licensed.observed_at ].min, at)
      end
      if (contract = latest(account, "contract_value"))
        signals << number_signal("contract_value", contract.numeric_value,
          "account_input", contract.source_locator, contract.observed_at, at)
      end
      signals
    end

    def number_signal(key, value, source_kind, locator, starts_at, ends_at)
      Signal.new(signal_key: key, value_kind: "number", numeric_value: value, date_value: nil,
        weight: 0, risk_points: 0, source_kind:, source_locator: locator,
        range_starts_at: starts_at, range_ends_at: ends_at)
    end

    def date_signal(key, value, input, at)
      Signal.new(signal_key: key, value_kind: "date", numeric_value: nil, date_value: value,
        weight: 0, risk_points: 0, source_kind: "account_input", source_locator: input.source_locator,
        range_starts_at: input.observed_at, range_ends_at: at)
    end

    def latest(account, key)
      self.class.latest_input(account, key)
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
