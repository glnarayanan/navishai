class HealthScorecardBacktester
  class InvalidBacktest < StandardError; end
  MAX_SNAPSHOTS = 500

  def self.run!(workspace:, membership:, version:, at: Time.current)
    actor = workspace.memberships.find(membership.id)
    raise Current::RoleAccessDenied unless actor.can_write?
    scorecard = HealthScorecardDesigner.install_default!(workspace:)
    version = scorecard.versions.find(version.id)
    HealthScorecardBacktest.transaction do
      version.lock!
      snapshots = load_snapshots(workspace)
      total = workspace.account_health_assessments.count
      rows = snapshots.map { |assessment| result_for(assessment, version.definition) }
      digest = source_digest(snapshots, version.definition)
      current_ids = current_assessment_ids(workspace, snapshots)
      results = {
        "current" => rows.select { |row| current_ids.include?(row.fetch("assessment_id")) },
        "history" => rows,
        "summary" => summary(rows).merge(
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
    source_digest(load_snapshots(workspace), version.definition)
  end

  def self.load_snapshots(workspace)
    workspace.account_health_assessments.includes(:account, :signals)
      .order(calculated_at: :desc, id: :desc).limit(MAX_SNAPSHOTS).to_a
  end
  private_class_method :load_snapshots

  def self.source_digest(snapshots, definition)
    source = snapshots.map do |assessment|
      {
        "assessment_id" => assessment.id, "calculated_at" => assessment.calculated_at.iso8601,
        "signals" => assessment.signals.map do |signal|
          [ signal.signal_key, signal.numeric_value&.to_s("F"), signal.date_value&.iso8601 ]
        end.sort
      }
    end
    Digest::SHA256.hexdigest(JSON.generate("definition" => definition, "source" => source))
  end
  private_class_method :source_digest

  def self.current_assessment_ids(workspace, snapshots)
    account_ids = snapshots.map(&:account_id).uniq
    return Set.new if account_ids.empty?

    workspace.account_health_assessments
      .where(account_id: account_ids)
      .select("DISTINCT ON (account_health_assessments.account_id) account_health_assessments.id")
      .reorder(:account_id, calculated_at: :desc, id: :desc)
      .map(&:id)
      .to_set
  end
  private_class_method :current_assessment_ids

  def self.result_for(assessment, definition)
    proposed = HealthScorecardDefinition.score(
      signals: assessment.signals, definition:, calculated_at: assessment.calculated_at
    )
    {
      "assessment_id" => assessment.id, "account_id" => assessment.account_id,
      "account_name" => assessment.account.name, "calculated_at" => assessment.calculated_at.iso8601,
      "existing_score" => assessment.score, "existing_risk_level" => assessment.risk_level,
      "proposed_score" => proposed.fetch(:score), "proposed_risk_level" => proposed.fetch(:risk_level)
    }
  end
  private_class_method :result_for

  def self.summary(rows)
    {
      "changed_count" => rows.count { |row| row.fetch("existing_score") != row.fetch("proposed_score") },
      "band_changed_count" => rows.count { |row| row.fetch("existing_risk_level") != row.fetch("proposed_risk_level") },
      "healthy_count" => rows.count { |row| row.fetch("proposed_risk_level") == "healthy" },
      "watch_count" => rows.count { |row| row.fetch("proposed_risk_level") == "watch" },
      "at_risk_count" => rows.count { |row| row.fetch("proposed_risk_level") == "at_risk" }
    }
  end
  private_class_method :summary
end
