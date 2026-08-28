class HumanEmailSend
  DELIVERY_LOCK_NAMESPACE = 24_081_126
  RecipientPreview = Data.define(:address, :trusted, :inbound_message_id)

  def self.send!(workspace:, support_case:, membership:, body:, draft_version:, idempotency_key:,
    source_crew_artifact_id: nil, expected_recipient_address: nil, expected_inbound_message_id: nil,
    confirmed_recipient_address: nil, transport: SharedEmailSmtpTransport.new)
    new(
      workspace:, support_case:, membership:, body:, draft_version:, idempotency_key:,
      source_crew_artifact_id:, expected_recipient_address:, expected_inbound_message_id:,
      confirmed_recipient_address:, transport:
    ).send!
  end

  def self.recipient_preview(workspace:, support_case:)
    current_case = workspace.support_cases.find(support_case.id)
    thread = workspace.email_threads.find_by!(conversation_id: current_case.conversation_id)
    recipient_for(workspace:, thread:)
  end

  def self.review_unknown!(workspace:, support_case:, membership:, delivery:, outcome:)
    raise ArgumentError, "invalid delivery outcome" unless %w[accepted rejected].include?(outcome.to_s)

    OutboundEmailDelivery.transaction do
      current_session = Session.active.lock.find(Current.session&.id)
      actor = workspace.memberships.lock.find(membership.id)
      raise Current::RoleAccessDenied unless actor.can_write? && actor.user == current_session.user

      current_case = workspace.support_cases.lock.find(support_case.id)
      current = workspace.outbound_email_deliveries.lock.find(delivery.id)
      raise ActiveRecord::RecordNotFound unless current.conversation_id == current_case.conversation_id
      review_lock = try_delivery_lock(current.id)
      raise ArgumentError, "the delivery attempt is still active" unless review_lock
      if current.sending?
        current.update!(status: :unknown, failure_code: "unknown_outcome")
        AuditEvent.record!(
          action: "email.send_failed", source: :web, workspace: workspace,
          actor: current.actor_user, subject: current, metadata: { failure_code: "unknown_outcome" }
        )
      elsif current.sent? || current.failed?
        same_outcome = (outcome.to_s == "accepted" && current.sent?) ||
          (outcome.to_s == "rejected" && current.failed? && current.failure_code == "confirmed_not_sent")
        raise ArgumentError, "this delivery was already reviewed with the opposite outcome" unless same_outcome

        return current
      end
      raise ArgumentError, "this delivery cannot be reviewed" unless current.unknown?

      if outcome.to_s == "accepted"
        message = ConversationThread.append_confirmed_outbound!(
          workspace: workspace, conversation: current.conversation,
          author_membership: current.actor_membership, reviewer_membership: actor,
          body: current.body, occurred_at: current.started_at, source: :web
        )
        workspace.email_message_links.create!(
          shared_email_inbox: current.shared_email_inbox,
          email_thread: current.email_thread,
          conversation: current.conversation,
          conversation_message: message,
          message_id: current.message_id
        )
        current.stored_attachments.each do |attachment|
          workspace.conversation_message_attachments.create!(
            conversation: current.conversation,
            conversation_message: message,
            stored_attachment: attachment
          )
        end
        current.update!(status: :sent, failure_code: nil, conversation_message: message, sent_at: current.started_at)
        current.email_draft.update!(status: :sent)
        AuditEvent.record!(action: "email.send_succeeded", source: :web, workspace: workspace, actor: current.actor_user, subject: current)
      else
        current.update!(status: :failed, failure_code: "confirmed_not_sent")
        current.email_draft.update!(status: :ready)
      end
      AuditEvent.record!(
        action: "email.send_reviewed", source: :web, workspace: workspace,
        actor: actor.user, subject: current, metadata: { outcome: outcome.to_s }
      )
      current
    end
  end

  def self.try_delivery_lock(delivery_id)
    value = OutboundEmailDelivery.connection.raw_connection.exec_params(
      "SELECT pg_try_advisory_xact_lock($1, $2)",
      [ DELIVERY_LOCK_NAMESPACE, Integer(delivery_id) ]
    ).getvalue(0, 0)
    ActiveModel::Type::Boolean.new.cast(value)
  end
  private_class_method :try_delivery_lock

  def initialize(workspace:, support_case:, membership:, body:, draft_version:, idempotency_key:,
    source_crew_artifact_id:, expected_recipient_address:, expected_inbound_message_id:,
    confirmed_recipient_address:, transport:)
    @workspace = workspace
    @support_case = support_case
    @membership = membership
    @body = body
    @draft_version = draft_version.to_s
    @idempotency_key = idempotency_key.to_s
    @source_crew_artifact_id = source_crew_artifact_id
    @expected_recipient_address = expected_recipient_address.to_s
    @expected_inbound_message_id = expected_inbound_message_id.to_s
    @confirmed_recipient_address = confirmed_recipient_address.to_s
    @transport = transport
  end

  def send!
    delivery, claimed = claim!
    return delivery unless claimed

    smtp_attempted = smtp_accepted = false
    attachments = begin
      delivery.stored_attachments.map do |attachment|
        {
          filename: attachment.filename,
          content_type: attachment.detected_content_type,
          content: attachment.download_verified!
        }
      end
    rescue StandardError
      return fail!(delivery, "attachment_unavailable", retryable: true)
    end
    HumanSendAuthorization.with_current_authority(workspace: @workspace, membership: @membership) do
      smtp_attempted = true
      @transport.deliver!(
        inbox: delivery.shared_email_inbox,
        message_id: delivery.message_id,
        in_reply_to: delivery.in_reply_to_message_id,
        references: [ delivery.email_thread.thread_key, delivery.in_reply_to_message_id ].compact.uniq,
        to: delivery.to_address,
        subject: delivery.subject,
        body: delivery.body,
        attachments: attachments
      )
    end
    smtp_accepted = true
    complete!(delivery)
  rescue Current::RoleAccessDenied, ActiveRecord::RecordNotFound
    if delivery
      smtp_attempted ? fail!(delivery, "unknown_outcome", retryable: false) :
        fail!(delivery, "authorization_changed", retryable: true)
    end
    raise
  rescue SharedEmailSmtpTransport::ConfigurationError
    fail!(delivery, "configuration_error", retryable: true)
  rescue Net::SMTPFatalError, Net::SMTPServerBusy, Net::SMTPAuthenticationError, Net::SMTPUnsupportedCommand
    fail!(delivery, "rejected", retryable: true)
  rescue IOError, SystemCallError, Timeout::Error, EOFError
    fail!(delivery, "unknown_outcome", retryable: false)
  rescue StandardError
    fail!(delivery, "unknown_outcome", retryable: false) if smtp_attempted || smtp_accepted
    raise
  ensure
    release_delivery_lock!
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
          body: @body, expected_lock_version: @draft_version,
          source_crew_artifact_id: @source_crew_artifact_id
        )
        draft.lock!
        raise ArgumentError, "draft is already being sent" unless draft.ready?
        HumanDraftProvenance.require_sendable!(draft)
        attachments = draft.stored_attachments.to_a
        unless attachments.all? { |attachment| attachment.available? && attachment.file.attached? }
          raise AttachmentIntake::InvalidAttachment, "Every attachment must pass malware scanning before send."
        end

        reply_link = self.class.send(:latest_inbound_link, thread)
        recipient = self.class.send(:recipient_for, workspace: @workspace, thread: thread, reply_link: reply_link)
        unless @expected_recipient_address == recipient.address && @expected_inbound_message_id == reply_link.message_id
          raise ArgumentError, "A new customer message arrived. Review the latest recipient and conversation before sending."
        end
        unless recipient.trusted || @confirmed_recipient_address == recipient.address
          raise ArgumentError, "confirm the recipient address before sending"
        end

        destination = recipient.address
        in_reply_to = reply_link.message_id
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
          started_at: [ Time.current, current_case.conversation.last_message_at ].compact.max,
          **HumanDraftProvenance.delivery_attributes(draft)
        )
        attachments.each do |attachment|
          @workspace.outbound_email_delivery_attachments.create!(
            outbound_email_delivery: delivery,
            stored_attachment: attachment
          )
        end
        draft.update!(status: :sending)
        AuditEvent.record!(action: "email.send_started", source: :web, workspace: @workspace, actor: actor.user, subject: delivery)
        acquire_delivery_lock!(delivery)
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
          occurred_at: [ Time.current, current.started_at ].max,
          source: :web
        )
        @workspace.email_message_links.create!(
          shared_email_inbox: current.shared_email_inbox,
          email_thread: current.email_thread,
          conversation: current.conversation,
          conversation_message: message,
          message_id: current.message_id
        )
        current.stored_attachments.each do |attachment|
          @workspace.conversation_message_attachments.create!(
            conversation: current.conversation,
            conversation_message: message,
            stored_attachment: attachment
          )
        end
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

    def self.recipient_for(workspace:, thread:, reply_link: latest_inbound_link(thread))
      address = reply_link.reply_to_address || fallback_destination(workspace:, thread:)
      contacts = [ thread.conversation.contact, thread.conversation.contact.canonical ].uniq
      trusted_addresses = contacts.flat_map do |contact|
        contact.source_identities.matched
          .joins(:source_identity_keys)
          .merge(SourceIdentityKey.current.where(kind: :email))
          .pluck("source_identity_keys.normalized_value")
      end
      RecipientPreview.new(
        address: address,
        trusted: trusted_addresses.include?(address),
        inbound_message_id: reply_link.message_id
      )
    end
    private_class_method :recipient_for

    def self.fallback_destination(workspace:, thread:)
      identities = workspace.source_identities.matched.where(
        source_namespace: "shared_email:#{thread.shared_email_inbox_id}",
        source_record_type: "sender"
      )
      identity = identities.find_by!(contact_id: thread.conversation.contact_id)
      raise ActiveRecord::RecordNotFound unless identity.canonical_record == thread.conversation.contact.canonical

      identity.source_record_id
    end
    private_class_method :fallback_destination

    def self.latest_inbound_link(thread)
      thread.email_message_links
        .joins(:conversation_message)
        .where(conversation_messages: { direction: :inbound })
        .order("conversation_messages.occurred_at DESC, conversation_messages.id DESC")
        .first!
    end
    private_class_method :latest_inbound_link

    def acquire_delivery_lock!(delivery)
      @locked_delivery_id = delivery.id
      OutboundEmailDelivery.connection.raw_connection.exec_params(
        "SELECT pg_advisory_lock($1, $2)",
        [ DELIVERY_LOCK_NAMESPACE, Integer(delivery.id) ]
      )
    end

    def release_delivery_lock!
      return unless @locked_delivery_id

      OutboundEmailDelivery.connection.raw_connection.exec_params(
        "SELECT pg_advisory_unlock($1, $2)",
        [ DELIVERY_LOCK_NAMESPACE, Integer(@locked_delivery_id) ]
      )
      @locked_delivery_id = nil
    end

    def reply_subject(subject)
      text = subject.to_s.squish.presence || "Support reply"
      text.match?(/\ARe:/i) ? text : "Re: #{text}"
    end
end
