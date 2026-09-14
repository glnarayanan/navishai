class HealthScorecardBacktester
  class InvalidBacktest < StandardError; end
  MAX_SNAPSHOTS = 500
  MAX_CURRENT_DETAILS = 100

  def self.run!(workspace:, membership:, version:, at: Time.current)
    actor = workspace.memberships.find(membership.id)
    raise Current::RoleAccessDenied unless actor.can_write?
    scorecard = HealthScorecardDesigner.install_default!(workspace:)
    version = scorecard.versions.find(version.id)
    HealthScorecardBacktest.transaction do
      version.lock!
      snapshots = load_snapshots(workspace)
      current = current_rows(workspace, version.definition)
      current_details = current.first(MAX_CURRENT_DETAILS)
      total = workspace.account_health_assessments.count
      rows = snapshots.map { |assessment| result_for(assessment, version.definition) }
      digest = source_digest(snapshots, current, version.definition)
      results = {
        "current" => current_details,
        "history" => rows,
        "summary" => summary(current).merge(
          "current_account_count" => current.size,
          "current_assessment_count" => current.count { |row| row.fetch("assessment_id").present? },
          "current_detail_count" => current_details.size,
          "current_detail_omitted_count" => current.size - current_details.size,
          "current_sampling_rule" => "lowest_account_id_first",
          "historical_snapshot_count" => rows.size,
          "historical_snapshot_omitted_count" => total - rows.size,
          "historical_sampling_rule" => "most_recent_by_calculated_at_then_id",
          "historical_starts_at" => rows.last&.fetch("calculated_at"),
          "historical_ends_at" => rows.first&.fetch("calculated_at"),
          "snapshot_limit" => MAX_SNAPSHOTS,
          "truncated" => total > snapshots.size
        )
      }
      backtest = version.backtests.create!(
        workspace:, membership: actor, user: actor.user, source_digest: digest,
        results:, sample_count: rows.size, generated_at: at
      )
      AuditEvent.record!(action: "scorecard.backtested", source: :web, workspace:, actor: actor.user,
        subject: backtest, metadata: { "version" => version.version_number, "sample_count" => rows.size })
      backtest
    end
  rescue ActiveRecord::RecordInvalid => error
    raise InvalidBacktest, error.record.errors.full_messages.to_sentence
  end

  def self.source_digest_for(workspace:, version:)
    source_digest(load_snapshots(workspace), current_rows(workspace, version.definition), version.definition)
  end

  def self.load_snapshots(workspace)
    workspace.account_health_assessments.includes(:account, :signals)
      .order(calculated_at: :desc, id: :desc).limit(MAX_SNAPSHOTS).to_a
  end
  private_class_method :load_snapshots

  def self.source_digest(snapshots, current, definition)
    historical_source = snapshots.map { |assessment| digest_source_for(assessment) }
    current_source = current.map do |row|
      row.slice("account_id", "assessment_id", "calculated_at", "comparison_status", "missing_signal_keys", "signal_reasons")
    end
    Digest::SHA256.hexdigest(JSON.generate(
      "definition" => definition, "historical_source" => historical_source, "current_source" => current_source
    ))
  end
  private_class_method :source_digest

  def self.current_rows(workspace, definition)
    accounts = workspace.accounts.order(:id).to_a
    assessments = current_assessments(workspace)
    assessments_by_account = assessments.index_by(&:account_id)
    accounts.map { |account| result_for(assessments_by_account[account.id], definition, account:) }
  end
  private_class_method :current_rows

  def self.current_assessments(workspace)
    workspace.account_health_assessments
      .includes(:account, :signals)
      .select("DISTINCT ON (account_health_assessments.account_id) account_health_assessments.*")
      .reorder(:account_id, calculated_at: :desc, id: :desc)
      .to_a
  end
  private_class_method :current_assessments

  def self.result_for(assessment, definition, account: assessment&.account)
    return no_data_result_for(account, definition) unless assessment

    signal_reasons = signal_reasons_for(assessment, definition)
    missing_signal_keys = signal_reasons.filter_map do |reason|
      reason.fetch("signal_key") if reason.fetch("status") == "missing_input"
    end
    comparison_status = if missing_signal_keys.any?
      "incomparable"
    end
    proposed = HealthScorecardDefinition.score(
      signals: assessment.signals, definition:, calculated_at: assessment.calculated_at
    ) unless comparison_status
    row = {
      "assessment_id" => assessment.id, "account_id" => assessment.account_id,
      "account_name" => assessment.account.name, "calculated_at" => assessment.calculated_at.iso8601,
      "existing_score" => assessment.score, "existing_risk_level" => assessment.risk_level,
      "proposed_score" => proposed&.fetch(:score), "proposed_risk_level" => proposed&.fetch(:risk_level),
      "missing_signal_keys" => missing_signal_keys, "signal_reasons" => signal_reasons
    }
    row["comparison_status"] = comparison_status ||
      (assessment.score == proposed.fetch(:score) && assessment.risk_level == proposed.fetch(:risk_level) ? "no_change" : "changed")
    row
  end
  private_class_method :result_for

  def self.no_data_result_for(account, definition)
    missing_signal_keys = definition.fetch("rules").pluck("signal_key")
    {
      "assessment_id" => nil, "account_id" => account.id, "account_name" => account.name,
      "calculated_at" => nil, "existing_score" => nil, "existing_risk_level" => nil,
      "proposed_score" => nil, "proposed_risk_level" => nil, "comparison_status" => "no_data",
      "missing_signal_keys" => missing_signal_keys,
      "signal_reasons" => missing_signal_keys.map do |signal_key|
        { "signal_key" => signal_key, "status" => "missing_input", "reason" => "No retained health assessment." }
      end
    }
  end
  private_class_method :no_data_result_for

  def self.signal_reasons_for(assessment, definition)
    signals = assessment.signals.index_by(&:signal_key)
    definition.fetch("rules").map do |rule|
      key = rule.fetch("signal_key")
      signal = signals[key]
      unless signal
        next { "signal_key" => key, "status" => "missing_input", "reason" => "This retained assessment has no #{key} input." }
      end

      existing_points = signal.risk_points
      proposed_points = proposed_risk_points_for(signal, rule, definition, assessment.calculated_at)
      {
        "signal_key" => key,
        "status" => "compared",
        "value" => signal.value_kind == "date" ? signal.date_value.iso8601 : signal.numeric_value.to_s("F"),
        "existing_risk_points" => existing_points,
        "proposed_risk_points" => proposed_points,
        "reason" => existing_points == proposed_points ?
          "Retained value keeps #{existing_points} risk points." :
          "Retained value changes risk points from #{existing_points} to #{proposed_points}."
      }
    end
  end
  private_class_method :signal_reasons_for

  def self.proposed_risk_points_for(signal, rule, definition, calculated_at)
    proposed = HealthScorecardDefinition.score(
      signals: [ signal ], definition: definition.merge("rules" => [ rule ]), calculated_at:
    )
    100 - proposed.fetch(:score)
  end
  private_class_method :proposed_risk_points_for

  def self.digest_source_for(assessment)
    {
      "assessment_id" => assessment.id, "calculated_at" => assessment.calculated_at.iso8601,
      "signals" => assessment.signals.map do |signal|
        [ signal.signal_key, signal.numeric_value&.to_s("F"), signal.date_value&.iso8601 ]
      end.sort
    }
  end
  private_class_method :digest_source_for

  def self.summary(rows)
    {
      "changed_count" => rows.count { |row| row.fetch("comparison_status") == "changed" },
      "no_change_count" => rows.count { |row| row.fetch("comparison_status") == "no_change" },
      "incomparable_count" => rows.count { |row| row.fetch("comparison_status") == "incomparable" },
      "no_data_count" => rows.count { |row| row.fetch("comparison_status") == "no_data" },
      "band_changed_count" => rows.count { |row| row.fetch("comparison_status") == "changed" && row.fetch("existing_risk_level") != row.fetch("proposed_risk_level") },
      "healthy_count" => rows.count { |row| row.fetch("proposed_risk_level") == "healthy" },
      "watch_count" => rows.count { |row| row.fetch("proposed_risk_level") == "watch" },
      "at_risk_count" => rows.count { |row| row.fetch("proposed_risk_level") == "at_risk" }
    }
  end
  private_class_method :summary
end
