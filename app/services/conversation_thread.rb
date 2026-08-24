class ConversationThread
  def self.start!(workspace:, contact:, membership:, subject: nil, occurred_at: Time.current)
    Conversation.transaction do
      actor = authorized_membership!(workspace, membership)
      current_contact = workspace.contacts.find(contact.id)
      conversation = workspace.conversations.create!(contact: current_contact, subject: subject, started_at: occurred_at)
      support_case = workspace.support_cases.create!(
        conversation: conversation,
        status: :new,
        priority: :normal,
        status_changed_at: occurred_at
      )
      workspace.support_case_status_changes.create!(
        support_case: support_case,
        from_status: nil,
        to_status: :new,
        actor_kind: :user,
        actor: actor.user,
        source: :web,
        reason: "case created",
        occurred_at: occurred_at
      )
      SlaEngine.start!(workspace: workspace, support_case: support_case, at: occurred_at)
      AuditEvent.record!(action: "conversation.created", source: :web, workspace: workspace, actor: actor.user, subject: conversation)
      AuditEvent.record!(action: "case.created", source: :web, workspace: workspace, actor: actor.user, subject: support_case)
      conversation
    end
  end

  def self.append_inbound!(workspace:, conversation:, author:, body:, occurred_at:, source:)
    raise ArgumentError, "unsupported source" unless AuditEvent::SOURCES.include?(source.to_s)

    Conversation.transaction do
      current_conversation = workspace.conversations.lock.find(conversation.id)
      current_author = workspace.contacts.find(author.id)
      raise ActiveRecord::RecordNotFound unless current_author == current_conversation.contact

      message = workspace.conversation_messages.create!(
        conversation: current_conversation,
        direction: :inbound,
        author_kind: :contact,
        author_contact: current_author,
        body: body,
        occurred_at: occurred_at
      )
      current_conversation.update!(last_message_at: [ current_conversation.last_message_at, occurred_at ].compact.max)
      CaseWorkflow.send(
        :resume_for_inbound!,
        workspace: workspace,
        support_case: current_conversation.support_case,
        message: message,
        source: source
      )
      AuditEvent.record!(
        action: "conversation.message_added",
        source: source,
        workspace: workspace,
        actor_kind: :system,
        subject: message,
        metadata: { direction: "inbound", author_kind: "contact" }
      )
      message
    end
  end

  def self.start_inbound!(workspace:, contact:, subject:, body:, occurred_at:, source:)
    raise ArgumentError, "unsupported source" unless AuditEvent::SOURCES.include?(source.to_s)

    Conversation.transaction do
      current_contact = workspace.contacts.find(contact.id)
      conversation = workspace.conversations.create!(
        contact: current_contact,
        subject: subject,
        started_at: occurred_at,
        last_message_at: occurred_at
      )
      support_case = workspace.support_cases.create!(
        conversation: conversation,
        status: :new,
        priority: :normal,
        status_changed_at: occurred_at
      )
      workspace.support_case_status_changes.create!(
        support_case: support_case,
        from_status: nil,
        to_status: :new,
        actor_kind: :system,
        source: source,
        reason: "case created from inbound message",
        occurred_at: occurred_at
      )
      message = workspace.conversation_messages.create!(
        conversation: conversation,
        direction: :inbound,
        author_kind: :contact,
        author_contact: current_contact,
        body: body,
        occurred_at: occurred_at
      )
      SlaEngine.start!(workspace: workspace, support_case: support_case, at: occurred_at)
      AuditEvent.record!(action: "conversation.created", source: source, workspace: workspace, actor_kind: :system, subject: conversation)
      AuditEvent.record!(action: "case.created", source: source, workspace: workspace, actor_kind: :system, subject: support_case)
      AuditEvent.record!(
        action: "conversation.message_added", source: source, workspace: workspace,
        actor_kind: :system, subject: message, metadata: { direction: "inbound", author_kind: "contact" }
      )
      message
    end
  end

  def self.append_outbound!(workspace:, conversation:, membership:, body:, occurred_at:, source:)
    raise ArgumentError, "unsupported source" unless AuditEvent::SOURCES.include?(source.to_s)

    Conversation.transaction do
      actor = authorized_membership!(workspace, membership)
      current_conversation = workspace.conversations.lock.find(conversation.id)
      message = workspace.conversation_messages.create!(
        conversation: current_conversation,
        direction: :outbound,
        author_kind: :user,
        author_user: actor.user,
        body: body,
        occurred_at: occurred_at
      )
      current_conversation.update!(last_message_at: [ current_conversation.last_message_at, occurred_at ].compact.max)
      SlaEngine.record_first_response!(
        workspace: workspace,
        support_case: current_conversation.support_case,
        message: message
      ) if current_conversation.support_case.case_sla
      AuditEvent.record!(
        action: "conversation.message_added", source: source, workspace: workspace,
        actor: actor.user, subject: message, metadata: { direction: "outbound", author_kind: "user" }
      )
      message
    end
  end

  def self.authorized_membership!(workspace, membership)
    workspace.memberships.lock.find(membership.id).tap do |current_membership|
      raise Current::RoleAccessDenied unless current_membership.can_write?
    end
  end
  private_class_method :authorized_membership!
end
