class NotificationFanout
  EVENT_DETAILS = {
    "case.assigned" => [ "assignment", "A case was assigned to you" ],
    "case.status_changed" => [ "review", "A case needs review" ],
    "sla.escalation_created" => [ "sla", "A case reached an SLA threshold" ],
    "sla.escalation_reactivated" => [ "sla", "An SLA alert is active again" ],
    "email.send_failed" => [ "failure", "An email send needs attention" ],
    "intercom.send_failed" => [ "failure", "An Intercom send needs attention" ],
    "intercom.sync_failed" => [ "failure", "An Intercom sync needs attention" ],
    "crew.task_event_recorded" => [ nil, nil ]
  }.freeze

  def self.call(audit_event)
    new(audit_event).call
  end

  def self.notifiable_action?(action)
    EVENT_DETAILS.key?(action)
  end

  def initialize(audit_event)
    @event = audit_event
    @workspace = audit_event.workspace
  end

  def call
    return 0 unless @workspace && self.class.notifiable_action?(@event.action)

    category, title = details
    return 0 unless category

    recipients.uniq.each do |membership|
      next if membership.user_id == @event.actor_id && category != "failure"

      @workspace.notifications.find_or_create_by!(
        recipient_membership: membership, source_audit_event: @event
      ) do |notification|
        notification.assign_attributes(category:, title:, path:, occurred_at: @event.occurred_at)
      end
    rescue ActiveRecord::RecordNotUnique
      nil
    end
    recipients.uniq.count { |membership| membership.user_id != @event.actor_id || category == "failure" }
  end

  private
    def details
      return crew_event_details if @event.action == "crew.task_event_recorded"
      return [ nil, nil ] if @event.action == "case.status_changed" && @event.metadata["to_status"] != "awaiting_human_review"

      EVENT_DETAILS.fetch(@event.action)
    end

    def crew_event_details
      case @event.metadata["event_kind"]
      when "status_changed"
        task = subject_task
        return [ "blocked", "Crew work is blocked" ] if task&.blocked?
        return [ "completion", "Crew work was completed" ] if task&.completed?
      when "review_requested"
        return [ "review", "Crew work needs review" ]
      end
      [ nil, nil ]
    end

    def recipients
      case @event.action
      when "case.assigned"
        @workspace.memberships.where(id: @event.metadata["assignee_id"]).to_a
      when "crew.task_event_recorded"
        task = subject_task
        task&.owner_membership ? [ task.owner_membership ] : managers
      else
        support_case&.assigned_membership ? [ support_case.assigned_membership ] : managers
      end
    end

    def managers
      @workspace.memberships.where(role: %w[owner admin manager]).to_a
    end

    def subject_task
      return @subject_task if defined?(@subject_task)

      @subject_task = case @event.subject_type
      when "CrewTask" then @workspace.crew_tasks.find_by(id: @event.subject_id)
      when "CrewTaskEvent" then @workspace.crew_task_events.find_by(id: @event.subject_id)&.crew_task
      end
    end

    def support_case
      return @support_case if defined?(@support_case)

      @support_case = case @event.subject_type
      when "SupportCase" then @workspace.support_cases.find_by(id: @event.subject_id)
      when "SlaEscalationTask" then @workspace.sla_escalation_tasks.find_by(id: @event.subject_id)&.case_sla&.support_case
      when "OutboundEmailDelivery"
        @workspace.outbound_email_deliveries.find_by(id: @event.subject_id)&.email_draft&.support_case
      when "IntercomOutboundDelivery"
        @workspace.intercom_outbound_deliveries.find_by(id: @event.subject_id)&.intercom_draft&.support_case
      when "IntercomSyncOperation"
        @workspace.intercom_sync_operations.find_by(id: @event.subject_id)&.intercom_conversation_link&.support_case
      end
    end

    def path
      if (case_record = support_case)
        Rails.application.routes.url_helpers.workspace_support_case_path(@workspace, case_record)
      elsif (task = subject_task)
        scope = task.support_case || task.account
        scope_name = task.support_case ? :workspace_support_case_crew_task_path : :workspace_account_crew_task_path
        Rails.application.routes.url_helpers.public_send(scope_name, @workspace, scope, task)
      else
        Rails.application.routes.url_helpers.workspace_support_cases_path(@workspace)
      end
    end
end
