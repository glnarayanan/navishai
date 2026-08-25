class AccountRiskWorkflow
  class InvalidCommand < StandardError; end

  def self.start!(workspace:, membership:, investigation:)
    membership = workspace.memberships.find(membership.id)
    raise Current::RoleAccessDenied unless membership.can_write?

    investigation = workspace.account_risk_investigations.find(investigation.id)
    AccountRiskInvestigation.transaction do
      investigation.lock!
      return investigation if investigation.investigating?
      raise InvalidCommand, "This risk review is already resolved." if investigation.resolved?

      profile = workspace.agent_profiles.find_by!(role_key: "risk_investigator")
      assessment = investigation.account_health_assessment
      task = CrewWork.create!(
        workspace:, membership:, scope: investigation.account, profile:,
        title: "Investigate #{investigation.account.name} renewal risk",
        input_context: "Assess health snapshot #{assessment.id} (#{assessment.score}/100, #{assessment.risk_level.humanize}). Separate deterministic facts from inference. State likely causes, evidence, uncertainty, and bounded interventions.",
        expected_output: "A cited risk investigation with uncertainty and recommended human-owned interventions."
      )
      investigation.update!(status: :investigating, crew_task: task)
      AuditEvent.record!(action: "account.risk_started", source: :web, workspace:, actor: membership.user,
        subject: investigation)
      investigation
    end
  rescue ActiveRecord::RecordInvalid => error
    raise InvalidCommand, error.record.errors.full_messages.to_sentence
  end

  def self.resolve!(workspace:, membership:, investigation:)
    membership = workspace.memberships.find(membership.id)
    raise Current::RoleAccessDenied unless membership.can_manage_work?
    investigation = workspace.account_risk_investigations.find(investigation.id)
    investigation.with_lock do
      return investigation if investigation.resolved?
      raise InvalidCommand, "Complete and review the crew investigation first." unless investigation.crew_task&.completed?

      investigation.update!(status: :resolved, resolved_at: Time.current)
      AuditEvent.record!(action: "account.risk_resolved", source: :web, workspace:, actor: membership.user,
        subject: investigation)
      investigation
    end
  end
end
