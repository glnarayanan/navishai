class CustomerSuccessInterventionWorkflow
  class InvalidCommand < StandardError; end

  MAX_SNAPSHOT_SIGNALS = 50

  def self.proposal_ready?(account:, assessment:, artifact:, investigation: nil)
    validate_proposal!(account:, assessment:, investigation:, artifact:)
    true
  rescue InvalidCommand
    false
  end

  def self.propose!(workspace:, membership:, account:, assessment:, artifact:, accountable_membership:,
    expected_observable_change:, target_on:, reason:, investigation: nil, at: Time.current)
    actor = workspace.memberships.find(membership.id)
    raise Current::RoleAccessDenied unless actor.can_write?

    account = workspace.accounts.find(account.id)
    assessment = workspace.account_health_assessments.find(assessment.id)
    investigation = workspace.account_risk_investigations.find(investigation.id) if investigation
    artifact = workspace.crew_artifacts.includes(:reviews, :revisions, crew_task: :account).find(artifact.id)
    accountable = workspace.memberships.find(accountable_membership.id)
    raise InvalidCommand, "Choose a human who can complete Account work." unless accountable.can_write?

    validate_proposal!(account:, assessment:, investigation:, artifact:)
    target_on = Date.iso8601(target_on.to_s)
    raise InvalidCommand, "Follow-up date cannot be before the proposal date." if target_on < at.to_date

    CustomerSuccessIntervention.transaction do
      intervention = workspace.customer_success_interventions.create!(
        account:, account_health_assessment: assessment, account_risk_investigation: investigation,
        proposing_crew_artifact: artifact, accountable_membership: accountable,
        proposed_by_membership: actor, status: :proposed,
        supporting_evidence: artifact.citations,
        expected_observable_change: bounded_text(expected_observable_change, 2_000, "Expected observable change"),
        target_on:, reason: bounded_text(reason, 1_000, "Reason"), proposed_at: at
      )
      audit!("account.intervention_proposed", workspace:, actor:, intervention:,
        metadata: { "from_state" => "none", "to_state" => "proposed" }, at:)
      intervention
    end
  rescue Date::Error, TypeError
    raise InvalidCommand, "Target date is invalid."
  rescue ActiveRecord::RecordInvalid => error
    raise InvalidCommand, error.record.errors.full_messages.to_sentence
  rescue ActiveRecord::RecordNotUnique
    raise InvalidCommand, "This AI proposal already has an intervention record."
  end

  def self.approve!(workspace:, membership:, intervention:, at: Time.current)
    transition!(workspace:, membership:, intervention:, from: "proposed", to: "approved", at:, manager: true) do |record, actor|
      record.approved_by_membership = actor
      record.approved_at = at
    end
  end

  def self.abandon!(workspace:, membership:, intervention:, reason:, at: Time.current)
    actor = workspace.memberships.find(membership.id)
    raise Current::RoleAccessDenied unless actor.can_manage_work?
    record = workspace.customer_success_interventions.find(intervention.id)
    record.with_lock do
      unless record.proposed? || record.approved?
        raise InvalidCommand, "Only a proposed or approved intervention can be abandoned."
      end
      from = record.status
      record.status = :abandoned
      record.abandoned_by_membership = actor
      record.abandoned_at = at
      record.abandonment_reason = bounded_text(reason, 1_000, "Abandonment reason")
      record.save!
      audit!("account.intervention_abandoned", workspace:, actor:, intervention: record,
        metadata: { "from_state" => from, "to_state" => "abandoned" }, at:)
      record
    end
  rescue ActiveRecord::RecordInvalid => error
    raise InvalidCommand, error.record.errors.full_messages.to_sentence
  end

  def self.complete!(workspace:, membership:, intervention:, at: Time.current)
    actor = workspace.memberships.find(membership.id)
    raise Current::RoleAccessDenied unless actor.can_write?
    record = workspace.customer_success_interventions.find(intervention.id)
    record.with_lock do
      raise Current::RoleAccessDenied unless record.accountable_membership_id == actor.id

      transition!(workspace:, membership: actor, intervention: record,
        from: "approved", to: "completed", at:) do |locked, human|
        locked.completed_by_membership = human
        locked.completed_at = at
      end
    end
  end

  def self.reassign!(workspace:, membership:, intervention:, accountable_membership:, reason:, at: Time.current)
    actor = workspace.memberships.find(membership.id)
    raise Current::RoleAccessDenied unless actor.can_manage_work?
    record = workspace.customer_success_interventions.find(intervention.id)
    accountable = workspace.memberships.find(accountable_membership.id)
    raise InvalidCommand, "Choose a human who can complete Account work." unless accountable.can_write?
    change_reason = bounded_text(reason, 1_000, "Reassignment reason")

    record.with_lock do
      unless record.proposed? || record.approved?
        raise InvalidCommand, "Only a proposed or approved intervention can be reassigned."
      end
      raise InvalidCommand, "Choose a different accountable human." if record.accountable_membership_id == accountable.id

      previous_id = record.accountable_membership_id
      record.update!(accountable_membership: accountable)
      audit!("account.intervention_reassigned", workspace:, actor:, intervention: record,
        metadata: {
          "previous_accountable_membership_id" => previous_id,
          "accountable_membership_id" => accountable.id,
          "reason" => change_reason
        }, at:)
      record
    end
  rescue ActiveRecord::RecordInvalid => error
    raise InvalidCommand, error.record.errors.full_messages.to_sentence
  end

  def self.reschedule!(workspace:, membership:, intervention:, target_on:, reason:, at: Time.current)
    actor = workspace.memberships.find(membership.id)
    raise Current::RoleAccessDenied unless actor.can_manage_work?
    record = workspace.customer_success_interventions.find(intervention.id)
    next_date = Date.iso8601(target_on.to_s)
    change_reason = bounded_text(reason, 1_000, "Follow-up date reason")

    record.with_lock do
      unless record.proposed? || record.approved?
        raise InvalidCommand, "Only a proposed or approved intervention can change its follow-up date."
      end
      raise InvalidCommand, "Follow-up date cannot be before the proposal date." if next_date < record.proposed_at.to_date
      raise InvalidCommand, "Choose a different follow-up date." if next_date == record.target_on

      previous = record.target_on
      record.update!(target_on: next_date)
      audit!("account.intervention_rescheduled", workspace:, actor:, intervention: record,
        metadata: {
          "previous_target_on" => previous.iso8601,
          "target_on" => next_date.iso8601,
          "reason" => change_reason
        }, at:)
      record
    end
  rescue Date::Error, TypeError
    raise InvalidCommand, "Target date is invalid."
  rescue ActiveRecord::RecordInvalid => error
    raise InvalidCommand, error.record.errors.full_messages.to_sentence
  end

  def self.review!(workspace:, membership:, intervention:, after_assessment:, uncertainty:, at: Time.current)
    actor = workspace.memberships.find(membership.id)
    raise Current::RoleAccessDenied unless actor.can_manage_work?
    record = workspace.customer_success_interventions.find(intervention.id)
    after_assessment = workspace.account_health_assessments.includes(:health_scorecard_version, :signals)
      .find(after_assessment.id)

    record.with_lock do
      raise InvalidCommand, "Complete the intervention before reviewing its outcome." unless record.completed?
      before = workspace.account_health_assessments.includes(:health_scorecard_version, :signals)
        .find(record.account_health_assessment_id)
      unless after_assessment.account_id == record.account_id &&
          after_assessment.calculated_at > before.calculated_at &&
          after_assessment.calculated_at >= record.completed_at
        raise InvalidCommand, "Choose a newer deterministic assessment calculated after completion."
      end

      before_snapshot = snapshot(before)
      after_snapshot = snapshot(after_assessment)
      changed, unchanged = compare_facts(before_snapshot, after_snapshot)
      review = workspace.customer_success_intervention_outcome_reviews.create!(
        customer_success_intervention: record,
        before_account_health_assessment: before,
        after_account_health_assessment: after_assessment,
        reviewed_by_membership: actor,
        before_snapshot:, after_snapshot:, changed_facts: changed, unchanged_facts: unchanged,
        uncertainty: bounded_text(uncertainty, 2_000, "Review uncertainty"),
        observed_association: association(before_snapshot, after_snapshot), reviewed_at: at
      )
      record.update!(status: :reviewed)
      audit!("account.intervention_reviewed", workspace:, actor:, intervention: record,
        metadata: { "from_state" => "completed", "to_state" => "reviewed" }, at:)
      review
    end
  rescue ActiveRecord::RecordInvalid => error
    raise InvalidCommand, error.record.errors.full_messages.to_sentence
  end

  def self.validate_proposal!(account:, assessment:, investigation:, artifact:)
    raise InvalidCommand, "The assessment belongs to another Account." unless assessment.account_id == account.id
    if investigation && (investigation.account_id != account.id ||
        investigation.account_health_assessment_id != assessment.id)
      raise InvalidCommand, "The risk review does not match the originating assessment."
    end
    unless artifact.intervention_plan? && artifact.crew_task.account_id == account.id &&
        artifact.schema_version == 2 && artifact.contract_result_state == "complete" && artifact.revisions.empty?
      raise InvalidCommand, "Choose the latest complete intervention plan for this Account."
    end
    assessment_prefix = "health://assessments/#{assessment.id}/signals/"
    unless artifact.citations.any? do |citation|
      citation["kind"] == "health_signal" && citation["locator"].to_s.start_with?(assessment_prefix)
    end
      raise InvalidCommand, "The intervention plan must cite the originating deterministic assessment."
    end
    latest_review = artifact.reviews.max_by { |review| [ review.created_at, review.id ] }
    unless latest_review&.success_review? && latest_review.review_outcome == "approved" &&
        latest_review.contract_result_state == "complete"
      raise InvalidCommand, "The intervention plan needs a complete approved success review."
    end
  end
  private_class_method :validate_proposal!

  def self.transition!(workspace:, membership:, intervention:, from:, to:, at:, manager: false)
    actor = workspace.memberships.find(membership.id)
    raise Current::RoleAccessDenied if manager && !actor.can_manage_work?
    record = workspace.customer_success_interventions.find(intervention.id)
    record.with_lock do
      raise InvalidCommand, "Only a #{from.humanize.downcase} intervention can be #{to}." unless record.status == from

      record.status = to
      yield record, actor
      record.save!
      audit!("account.intervention_#{to}", workspace:, actor:, intervention: record,
        metadata: { "from_state" => from, "to_state" => to }, at:)
      record
    end
  rescue ActiveRecord::RecordInvalid => error
    raise InvalidCommand, error.record.errors.full_messages.to_sentence
  end

  def self.snapshot(assessment)
    signals = assessment.signals.sort_by { |signal| [ signal.signal_key, signal.id ] }
    selected = signals.first(MAX_SNAPSHOT_SIGNALS)
    {
      "assessment_id" => assessment.id,
      "score" => assessment.score,
      "risk_level" => assessment.risk_level,
      "calculated_at" => assessment.calculated_at.iso8601(6),
      "scorecard_version_id" => assessment.health_scorecard_version_id,
      "scorecard_version" => assessment.health_scorecard_version.version_number,
      "signals" => selected.map { |signal| signal_snapshot(signal) },
      "signals_omitted_count" => signals.size - selected.size
    }
  end
  private_class_method :snapshot

  def self.signal_snapshot(signal)
    value = signal.value_kind == "date" ? signal.date_value.iso8601 : signal.numeric_value.to_s("F")
    {
      "id" => signal.id, "signal_key" => signal.signal_key, "value_kind" => signal.value_kind,
      "value" => value, "weight" => signal.weight, "risk_points" => signal.risk_points,
      "source_kind" => signal.source_kind, "source_locator" => signal.source_locator,
      "range_starts_at" => signal.range_starts_at&.iso8601(6),
      "range_ends_at" => signal.range_ends_at.iso8601(6),
      "evidence_refs" => signal.evidence_refs,
      "evidence_omitted_count" => signal.evidence_omitted_count
    }
  end
  private_class_method :signal_snapshot

  def self.compare_facts(before_snapshot, after_snapshot)
    before = before_snapshot.fetch("signals").index_by { |signal| signal.fetch("signal_key") }
    after = after_snapshot.fetch("signals").index_by { |signal| signal.fetch("signal_key") }
    changed = []
    unchanged = []
    (before.keys | after.keys).sort.each do |key|
      before_value = comparable_fact(before[key])
      after_value = comparable_fact(after[key])
      if before_value == after_value
        unchanged << key
      else
        changed << { "signal_key" => key, "before" => before_value, "after" => after_value }
      end
    end
    [ changed.first(CustomerSuccessInterventionOutcomeReview::MAX_FACTS),
      unchanged.first(CustomerSuccessInterventionOutcomeReview::MAX_FACTS) ]
  end
  private_class_method :compare_facts

  def self.comparable_fact(signal)
    signal&.slice("value_kind", "value", "weight", "risk_points")
  end
  private_class_method :comparable_fact

  def self.association(before_snapshot, after_snapshot)
    before_score = before_snapshot.fetch("score")
    after_score = after_snapshot.fetch("score")
    before_risk = before_snapshot.fetch("risk_level").humanize.downcase
    after_risk = after_snapshot.fetch("risk_level").humanize.downcase
    change = if before_score == after_score && before_risk == after_risk
      "No score or risk-level change was observed"
    else
      "Deterministic health moved from #{before_score}/100 (#{before_risk}) to #{after_score}/100 (#{after_risk})"
    end
    "#{change} after the intervention was recorded. This reports timing and association only; it does not assign cause."
  end
  private_class_method :association

  def self.bounded_text(value, maximum, name)
    text = value.to_s.strip
    raise InvalidCommand, "#{name} is required and must be at most #{maximum} bytes." if
      text.blank? || text.bytesize > maximum
    text
  end
  private_class_method :bounded_text

  def self.audit!(action, workspace:, actor:, intervention:, metadata:, at:)
    AuditEvent.record!(action:, source: :web, workspace:, actor: actor.user,
      subject: intervention, metadata:, occurred_at: at)
  end
  private_class_method :audit!
end
