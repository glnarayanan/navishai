class CustomerSuccessInterventionDueNotices
  def self.deliver!(workspace:, as_of: Date.current)
    workspace.customer_success_interventions
      .includes(:accountable_membership)
      .where(status: %w[proposed approved])
      .find_each
      .sum { |intervention| deliver_for!(workspace:, intervention:, as_of:) }
  end

  def self.deliver_for!(workspace:, intervention:, as_of:)
    due_state = due_state_for(intervention.target_on, as_of)
    return 0 unless due_state

    recipient = intervention.accountable_membership
    return 0 unless recipient&.can_write?

    notice = CustomerSuccessInterventionDueNotice.transaction do
      intervention.lock!
      next unless intervention.proposed? || intervention.approved?
      next unless intervention.accountable_membership_id == recipient.id
      next unless recipient.reload.can_write?
      next unless due_state_for(intervention.target_on, as_of) == due_state
      next if CustomerSuccessInterventionDueNotice.exists?(
        customer_success_intervention_id: intervention.id,
        recipient_membership_id: recipient.id,
        due_state:,
        target_on: intervention.target_on
      )

      event = AuditEvent.record!(
        action: "account.intervention_due", source: :job, workspace:, actor_kind: :system,
        subject: intervention,
        metadata: {
          "due_state" => due_state,
          "recipient_membership_id" => recipient.id,
          "target_on" => intervention.target_on.iso8601
        }
      )
      workspace.customer_success_intervention_due_notices.create!(
        customer_success_intervention: intervention,
        recipient_membership: recipient,
        due_state:,
        target_on: intervention.target_on,
        source_audit_event: event,
        notified_at: Time.current
      )
    end
    notice ? 1 : 0
  rescue ActiveRecord::RecordNotUnique
    0
  end
  private_class_method :deliver_for!

  def self.due_state_for(target_on, as_of)
    if target_on < as_of
      "overdue"
    elsif target_on == as_of
      "due"
    end
  end
  private_class_method :due_state_for
end
