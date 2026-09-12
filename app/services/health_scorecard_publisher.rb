class HealthScorecardPublisher
  class InvalidPublish < StandardError; end

  def self.publish!(workspace:, membership:, version:, expected_current_version_id:, expected_backtest_id:)
    change_current!(workspace:, membership:, version:, expected_current_version_id:, expected_backtest_id:,
      action: "scorecard.published")
  end

  def self.rollback!(workspace:, membership:, version:, expected_current_version_id:, expected_backtest_id:)
    change_current!(workspace:, membership:, version:, expected_current_version_id:, expected_backtest_id:,
      action: "scorecard.rolled_back")
  end

  def self.change_current!(workspace:, membership:, version:, expected_current_version_id:, expected_backtest_id:, action:)
    actor = workspace.memberships.find(membership.id)
    raise Current::RoleAccessDenied unless actor.can_configure_agents?
    scorecard = HealthScorecardDesigner.install_default!(workspace:)
    version = scorecard.versions.find(version.id)
    inspected = inspected_backtest!(workspace, version, expected_backtest_id)

    HealthScorecard.transaction do
      scorecard.lock!
      return scorecard.current_version if scorecard.current_version_id == version.id
      unless scorecard.current_version_id.to_s == expected_current_version_id.to_s
        raise InvalidPublish, "The published version changed after this page loaded. Review it and try again."
      end
      from_version = scorecard.current_version
      scorecard.update!(current_version: version)
      AuditEvent.record!(action:, source: :web, workspace:, actor: actor.user, subject: version,
        metadata: {
          "from_version" => from_version.version_number,
          "to_version" => version.version_number,
          "backtest_id" => inspected.id
        })
      version
    end
  end
  private_class_method :change_current!

  def self.inspected_backtest!(workspace, version, expected_backtest_id)
    latest = version.backtests.order(generated_at: :desc, id: :desc).first
    raise InvalidPublish, "Run a fresh preview and backtest before publishing this version." if latest.nil?
    unless latest.id.to_s == expected_backtest_id.to_s
      raise InvalidPublish, "The preview on this page is not the inspected backtest. Refresh it and try again."
    end
    fresh = HealthScorecardBacktester.source_digest_for(workspace:, version:)
    unless latest.source_digest == fresh
      raise InvalidPublish, "Retained snapshots changed after this preview. Refresh it before publishing."
    end
    latest
  end
  private_class_method :inspected_backtest!
end
