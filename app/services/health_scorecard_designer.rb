class HealthScorecardDesigner
  class InvalidProposal < StandardError; end

  def self.install_default!(workspace:)
    HealthScorecard.transaction do
      scorecard = workspace.health_scorecard || workspace.build_health_scorecard(name: "Account health")
      return scorecard if scorecard.persisted? && scorecard.current_version
      scorecard.save!
      version = scorecard.versions.create!(
        workspace:, version_number: 1, design_prompt: HealthScorecardDefinition::DEFAULT_PROMPT,
        explanation: "Balances support load, SLA breaches, customer inactivity, renewal timing, and seat use.",
        definition: HealthScorecardDefinition.default
      )
      scorecard.update!(current_version: version)
      scorecard
    end
  end

  def self.propose!(workspace:, membership:, prompt:, healthy_min: nil, watch_min: nil, weights: nil,
    definition: nil, explanation: nil, source_proposal: nil)
    actor = workspace.memberships.find(membership.id)
    raise Current::RoleAccessDenied unless actor.can_write?
    prompt = prompt.to_s.strip
    raise InvalidProposal, "Describe the outcome this scorecard should track." unless prompt.bytesize.in?(1..4_000)
    if source_proposal && (source_proposal.workspace_id != workspace.id || !source_proposal.acceptable?)
      raise InvalidProposal, "Only a valid unused proposal from this Workspace can be accepted."
    end
    definition = if definition
      HealthScorecardDefinition.validate!(definition)
      definition
    else
      HealthScorecardDefinition.build(healthy_min:, watch_min:, weights:)
    end
    explanation = explanation.to_s.strip.presence || explain(definition)
    scorecard = install_default!(workspace:)

    HealthScorecardVersion.transaction do
      scorecard.lock!
      version = scorecard.versions.create!(
        workspace:, version_number: scorecard.versions.maximum(:version_number).to_i + 1,
        design_prompt: prompt, explanation:, definition:,
        created_by_membership: actor, created_by_user: actor.user,
        source_proposal:
      )
      scorecard.design_turns.create!(
        workspace:, health_scorecard_version: version, membership: actor, user: actor.user,
        prompt:, response: version.explanation
      )
      AuditEvent.record!(action: "scorecard.proposed", source: :web, workspace:, actor: actor.user,
        subject: version, metadata: { "version" => version.version_number, "proposal_id" => source_proposal&.id }.compact)
      version
    end
  rescue HealthScorecardDefinition::InvalidDefinition, ActiveRecord::RecordInvalid => error
    raise InvalidProposal, error.message
  end

  def self.explain(definition)
    rules = definition.fetch("rules").map do |rule|
      entry = HealthScorecardDefinition::CATALOG.fetch(rule.fetch("signal_key"))
      "#{entry.fetch(:label)} carries up to #{rule.fetch('weight')} points. #{entry.fetch(:detail)}"
    end
    "I mapped your outcome to #{rules.size} deterministic signals. Healthy starts at #{definition.fetch('healthy_min')}; watch starts at #{definition.fetch('watch_min')}. #{rules.join(' ')}"
  end
  private_class_method :explain
end
