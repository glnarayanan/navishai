class HumanEmailSend
  def self.send!(workspace:, support_case:, membership:, body:, draft_version:, idempotency_key:, transport: SharedEmailSmtpTransport.new)
    new(workspace:, support_case:, membership:, body:, draft_version:, idempotency_key:, transport:).send!
  end

  def initialize(workspace:, support_case:, membership:, body:, draft_version:, idempotency_key:, transport:)
    @workspace = workspace
    @support_case = support_case
    @membership = membership
    @body = body
    @draft_version = draft_version.to_s
    @idempotency_key = idempotency_key.to_s
    @transport = transport
  end

  def send!
    delivery, claimed = claim!
    return delivery unless claimed

    smtp_accepted = false
    @transport.deliver!(
      inbox: delivery.shared_email_inbox,
      message_id: delivery.message_id,
      in_reply_to: delivery.in_reply_to_message_id,
      references: [ delivery.email_thread.thread_key, delivery.in_reply_to_message_id ].compact.uniq,
      to: delivery.to_address,
      subject: delivery.subject,
      body: delivery.body
    )
    smtp_accepted = true
    complete!(delivery)
  rescue SharedEmailSmtpTransport::ConfigurationError
    fail!(delivery, "configuration_error", retryable: true)
  rescue Net::SMTPFatalError, Net::SMTPServerBusy, Net::SMTPAuthenticationError, Net::SMTPUnsupportedCommand
    fail!(delivery, "rejected", retryable: true)
  rescue IOError, SystemCallError, Timeout::Error, EOFError
    fail!(delivery, "unknown_outcome", retryable: false)
  rescue StandardError
    fail!(delivery, "unknown_outcome", retryable: false) if smtp_accepted
    raise
  end

  private
    def claim!
      OutboundEmailDelivery.transaction do
        raise ArgumentError, "idempotency key is required" if @idempotency_key.blank? || @idempotency_key.length > 100

        current_session = Session.active.lock.find(Current.session&.id)
        actor = @workspace.memberships.lock.find(@membership.id)
        raise Current::RoleAccessDenied unless actor.can_write? && actor.user == current_session.user
        current_case = @workspace.support_cases.lock.find(@support_case.id)
        existing = @workspace.outbound_email_deliveries.find_by(idempotency_key: @idempotency_key)
        if existing
          raise ActiveRecord::RecordNotFound unless existing.email_draft.support_case_id == current_case.id

          return [ existing, false ]
        end

        thread = @workspace.email_threads.includes(:shared_email_inbox).find_by!(conversation_id: current_case.conversation_id)
        raise ActiveRecord::RecordNotFound unless thread.shared_email_inbox.active?

        draft = EmailDraftWorkflow.save!(
          workspace: @workspace, support_case: current_case, membership: actor,
          body: @body, expected_lock_version: @draft_version
        )
        draft.lock!
        raise ArgumentError, "draft is already being sent" unless draft.ready?

        destination = destination_for(thread)
        in_reply_to = thread.email_message_links.order(created_at: :desc, id: :desc).pick(:message_id)
        delivery = @workspace.outbound_email_deliveries.create!(
          email_draft: draft,
          shared_email_inbox: thread.shared_email_inbox,
          email_thread: thread,
          conversation: current_case.conversation,
          actor_membership: actor,
          actor_user: actor.user,
          idempotency_key: @idempotency_key,
          message_id: "#{SecureRandom.uuid}@navishai.local",
          in_reply_to_message_id: in_reply_to,
          from_address: thread.shared_email_inbox.email_address,
          to_address: destination,
          subject: reply_subject(current_case.conversation.subject),
          body: draft.body,
          started_at: Time.current
        )
        draft.update!(status: :sending)
        AuditEvent.record!(action: "email.send_started", source: :web, workspace: @workspace, actor: actor.user, subject: delivery)
        [ delivery, true ]
      end
    end

    def complete!(delivery)
      OutboundEmailDelivery.transaction do
        current = @workspace.outbound_email_deliveries.lock.find(delivery.id)
        return current unless current.sending?

        message = ConversationThread.append_outbound!(
          workspace: @workspace,
          conversation: current.conversation,
          membership: current.actor_membership,
          body: current.body,
          occurred_at: Time.current,
          source: :web
        )
        @workspace.email_message_links.create!(
          shared_email_inbox: current.shared_email_inbox,
          email_thread: current.email_thread,
          conversation: current.conversation,
          conversation_message: message,
          message_id: current.message_id
        )
        current.update!(status: :sent, conversation_message: message, sent_at: message.occurred_at)
        current.email_draft.update!(status: :sent)
        AuditEvent.record!(action: "email.send_succeeded", source: :web, workspace: @workspace, actor: current.actor_user, subject: current)
        current
      end
    end

    def fail!(delivery, code, retryable:)
      raise unless delivery

      OutboundEmailDelivery.transaction do
        current = @workspace.outbound_email_deliveries.lock.find(delivery.id)
        return current unless current.sending?

        current.update!(status: retryable ? :failed : :unknown, failure_code: code)
        current.email_draft.update!(status: :ready) if retryable
        AuditEvent.record!(action: "email.send_failed", source: :web, workspace: @workspace, actor: current.actor_user, subject: current, metadata: { failure_code: code })
        current
      end
    end

    def destination_for(thread)
      identities = @workspace.source_identities.matched.where(
        source_namespace: "shared_email:#{thread.shared_email_inbox_id}",
        source_record_type: "sender"
      )
      identity = identities.find_by!(contact_id: thread.conversation.contact_id)
      raise ActiveRecord::RecordNotFound unless identity.canonical_record == thread.conversation.contact.canonical

      identity.source_record_id
    end

    def reply_subject(subject)
      text = subject.to_s.squish.presence || "Support reply"
      text.match?(/\ARe:/i) ? text : "Re: #{text}"
    end
end
