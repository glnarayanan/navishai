require "mail"

class SharedEmailIntake
  MAX_BODY_BYTES = 1.megabyte
  MAX_RECONCILIATION_ATTEMPTS = 5

  class Conflict < StandardError; end
  class ProcessingError < StandardError
    attr_reader :code

    def initialize(code)
      @code = code
      super(code.tr("_", " "))
    end
  end

  def self.receive!(inbox:, raw_email:, received_at: Time.current)
    new(inbox: inbox, raw_email: raw_email, received_at: received_at).receive!
  end

  def self.reconcile!(inbox:, membership:, limit: 100)
    raise ActiveRecord::RecordNotFound unless inbox.active?
    actor = inbox.workspace.memberships.find(membership.id)
    raise Current::RoleAccessDenied unless actor.can_configure_integrations?

    inbox.inbound_email_deliveries.outstanding.order(Arel.sql("CASE status WHEN 'received' THEN 0 ELSE 1 END"), :received_at, :id).limit(limit).filter_map do |delivery|
      new(inbox: inbox, raw_email: delivery.raw_email, received_at: delivery.received_at).retry!(delivery, actor: actor.user)
    end
  end

  def initialize(inbox:, raw_email:, received_at:)
    @inbox = inbox
    @workspace = inbox.workspace
    @raw_email = raw_email.to_s.b
    @received_at = received_at
    @digest = Digest::SHA256.hexdigest(@raw_email)
  end

  def receive!
    raise ActiveRecord::RecordNotFound unless @inbox.active?
    raise ProcessingError, "persistence_error" if @raw_email.bytesize > InboundEmailDelivery::MAX_BYTES

    mail = parse_mail
    message_id = normalized_message_id(mail.message_id)
    return persist_initial_failure!("missing_message_id") unless message_id

    delivery = persist_received!(message_id)
    raise Conflict, "message id was reused with different content" if delivery.failure_code == "message_id_conflict"
    return delivery unless delivery.received?

    process!(delivery, mail)
  rescue Mail::Field::ParseError, Mail::UnknownEncodingType, EncodingError
    persist_initial_failure!("parse_error")
  end

  def retry!(delivery, actor:)
    mail = parse_mail
    delivery.with_lock do
      return delivery if delivery.processed?
      previous_failure_code = delivery.failure_code
      delivery.update!(
        status: :received, failure_code: nil, processed_at: nil,
        attempt_count: delivery.attempt_count + 1, last_attempted_at: Time.current
      )
      AuditEvent.record!(
        action: "email.intake_retried", source: :web, workspace: @workspace,
        actor: actor, subject: delivery,
        metadata: previous_failure_code ? { failure_code: previous_failure_code } : {}
      )
    end
    process!(delivery, mail)
  rescue Mail::Field::ParseError, Mail::UnknownEncodingType, EncodingError
    mark_failed!(delivery, "parse_error")
  end

  private
    def parse_mail
      Mail.read_from_string(@raw_email)
    end

    def persist_received!(message_id)
      InboundEmailDelivery.transaction do
        lock_active_inbox!
        delivery = @inbox.inbound_email_deliveries.find_by(source_message_id: message_id, content_sha256: @digest)
        return delivery if delivery
        return persist_conflict!(message_id) if @inbox.inbound_email_deliveries.exists?(source_message_id: message_id)

        delivery = @inbox.inbound_email_deliveries.new(
          source_message_id: message_id,
          workspace: @workspace,
          content_sha256: @digest,
          raw_email: @raw_email,
          received_at: @received_at
        )
        delivery.save!
        AuditEvent.record!(
          action: "email.intake_received", source: :integration, workspace: @workspace,
          actor_kind: :system, subject: delivery
        )
        delivery
      end
    end

    def persist_conflict!(message_id)
      delivery = @inbox.inbound_email_deliveries.create!(
        workspace: @workspace,
        source_message_id: message_id,
        content_sha256: @digest,
        raw_email: @raw_email,
        status: :failed,
        failure_code: "message_id_conflict",
        received_at: @received_at,
        processed_at: Time.current
      )
      AuditEvent.record!(
        action: "email.intake_received", source: :integration, workspace: @workspace,
        actor_kind: :system, subject: delivery
      )
      audit_failure!(delivery, "message_id_conflict")
      delivery
    end

    def persist_initial_failure!(code)
      source_message_id = "sha256:#{@digest}"
      InboundEmailDelivery.transaction do
        lock_active_inbox!
        delivery = @inbox.inbound_email_deliveries.find_by(source_message_id: source_message_id)
        return delivery if delivery

        delivery = @inbox.inbound_email_deliveries.create!(
          workspace: @workspace,
          source_message_id: source_message_id,
          content_sha256: @digest,
          raw_email: @raw_email,
          status: :failed,
          failure_code: code,
          received_at: @received_at,
          processed_at: Time.current
        )
        AuditEvent.record!(
          action: "email.intake_received", source: :integration, workspace: @workspace,
          actor_kind: :system, subject: delivery
        )
        audit_failure!(delivery, code)
        delivery
      end
    end

    def process!(delivery, mail)
      sender_email, sender_name = sender(mail)
      raise ProcessingError, "missing_sender" unless sender_email

      body = plain_text_body(mail)
      raise ProcessingError, "empty_body" if body.blank?
      raise ProcessingError, "body_too_large" if body.bytesize > MAX_BODY_BYTES
      inputs = attachment_inputs(mail)
      prepared_attachments = AttachmentIntake.prepare!(inputs) if inputs.any?

      result = InboundEmailDelivery.transaction do
        current_delivery = @inbox.inbound_email_deliveries.lock.find(delivery.id)
        return current_delivery if current_delivery.processed?

        lock_active_inbox!
        identity = resolve_contact(sender_email, sender_name)
        unless identity.matched?
          current_delivery.update!(
            status: :failed, failure_code: "identity_ambiguous",
            processed_at: Time.current
          )
          audit_failure!(current_delivery, "identity_ambiguous")
          next current_delivery
        end

        thread, message = find_or_create_thread!(mail, identity.record, body)
        message ||= append_message!(thread, mail, identity.record, body)
        create_message_link!(thread, message, mail, reply_target(mail, sender_email))
        attachments = AttachmentIntake.persist!(
          workspace: @workspace, prepared: prepared_attachments || [],
          source: :inbound_email, message: message
        )
        attachments.each do |attachment|
          AuditEvent.record!(
            action: "attachment.uploaded", source: :integration, workspace: @workspace,
            actor_kind: :system, subject: attachment, metadata: { scan_status: attachment.scan_status }
          )
        end
        current_delivery.update!(
          status: :processed,
          conversation: thread.conversation,
          conversation_message: message,
          processed_at: Time.current
        )
        current_delivery
      end
      prepared_attachments = nil if result.processed?
      result
    rescue ProcessingError => error
      mark_failed!(delivery, error.code)
    rescue AttachmentIntake::InvalidAttachment
      mark_failed!(delivery, "persistence_error")
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, ActiveRecord::StatementInvalid
      mark_failed!(delivery, "persistence_error")
    rescue ArgumentError
      mark_failed!(delivery, "identity_error")
    ensure
      prepared_attachments&.each(&:purge!)
    end

    def resolve_contact(email, name)
      SourceIdentityResolver.resolve!(
        workspace: @workspace,
        entity_kind: :contact,
        source_namespace: "shared_email:#{@inbox.id}",
        source_record_type: :sender,
        source_record_id: email,
        keys: { email: email },
        attributes: { name: name.presence }
      )
    end

    def find_or_create_thread!(mail, contact, body)
      if linked_thread = linked_thread(mail)
        return [ linked_thread, nil ]
      end

      key = thread_key(mail)
      existing = @inbox.email_threads.find_by(thread_key: key)
      return [ existing, nil ] if existing

      message = ConversationThread.start_inbound!(
        workspace: @workspace,
        contact: contact,
        subject: mail.subject.to_s.squish.truncate(500),
        body: body,
        occurred_at: @received_at,
        source: :integration
      )
      thread = @inbox.email_threads.create!(
        workspace: @workspace,
        conversation: message.conversation,
        thread_key: key
      )
      [ thread, message ]
    end

    def append_message!(thread, mail, contact, body)
      conversation_contact = thread.conversation.contact
      raise ActiveRecord::RecordNotFound unless conversation_contact.canonical == contact.canonical

      ConversationThread.append_inbound!(
        workspace: @workspace,
        conversation: thread.conversation,
        author: conversation_contact,
        body: body,
        occurred_at: @received_at,
        source: :integration
      )
    end

    def create_message_link!(thread, message, mail, reply_to_address)
      message_id = normalized_message_id(mail.message_id)
      @inbox.email_message_links.create!(
        workspace: @workspace,
        email_thread: thread,
        conversation: thread.conversation,
        conversation_message: message,
        message_id: message_id,
        reply_to_address: reply_to_address
      )
    end

    def reply_target(mail, sender_email)
      field = mail[:reply_to]
      address = field.addresses&.first if field.respond_to?(:addresses)
      address ? IdentityKeyNormalizer.normalize(:email, address) : sender_email
    rescue Mail::Field::ParseError, ArgumentError
      sender_email
    end

    def thread_key(mail)
      references = message_ids(mail.references)
      references.first || message_ids(mail.in_reply_to).first || normalized_message_id(mail.message_id)
    end

    def linked_thread(mail)
      referenced_ids = message_ids(mail.references) + message_ids(mail.in_reply_to)
      return if referenced_ids.empty?

      links = @inbox.email_message_links.where(message_id: referenced_ids).includes(:email_thread).index_by(&:message_id)
      referenced_ids.filter_map { |message_id| links[message_id]&.email_thread }.first
    end

    def sender(mail)
      email = mail[:from]&.addresses&.first
      return unless email

      name = mail[:from]&.display_names&.first
      [ IdentityKeyNormalizer.normalize(:email, email), name.to_s.strip.presence ]
    rescue ArgumentError
      nil
    end

    def plain_text_body(mail)
      text = if mail.multipart?
        plain = body_parts(mail, "text/plain").map(&:decoded).join("\n")
        html = body_parts(mail, "text/html").map(&:decoded).join("\n")
        plain.presence || html_to_text(html)
      elsif mail.mime_type == "text/html"
        html_to_text(mail.decoded)
      else
        mail.decoded
      end
      text.to_s.encode("UTF-8", invalid: :replace, undef: :replace).strip
    end

    def body_parts(container, mime_type)
      container.parts.flat_map do |part|
        next [] if part.filename.present? || part.content_disposition.to_s.match?(/\Aattachment(?:;|\z)/i) || part.mime_type == "message/rfc822"

        part.multipart? ? body_parts(part, mime_type) : (part.mime_type == mime_type ? [ part ] : [])
      end
    end

    def attachment_inputs(mail)
      return [] unless mail.multipart?

      leaf_parts(mail).filter_map.with_index do |part, index|
        attachment = part.filename.present? || part.content_disposition.to_s.match?(/\Aattachment(?:;|\z)/i) || !%w[text/plain text/html].include?(part.mime_type)
        { filename: part.filename.presence || "attachment-#{index + 1}", data: part.decoded } if attachment
      end
    end

    def leaf_parts(container)
      container.parts.flat_map { |part| part.multipart? && part.mime_type != "message/rfc822" ? leaf_parts(part) : [ part ] }
    end

    def html_to_text(html)
      fragment = Nokogiri::HTML5.fragment(html)
      fragment.css("script, style").remove
      fragment.text.squish
    end

    def message_ids(value)
      Array(value).flat_map do |entry|
        bracketed = entry.to_s.scan(/<([^>]+)>/).flatten
        candidates = bracketed.presence || entry.to_s.split
        candidates.filter_map { |candidate| normalized_message_id(candidate) }
      end
    end

    def normalized_message_id(value)
      normalized = value.to_s.strip.delete_prefix("<").delete_suffix(">")
      normalized if normalized.length <= 998 && normalized.match?(/\A[^\s<>@]+@[^\s<>@]+\z/)
    end

    def lock_active_inbox!
      @inbox.lock!
      raise ActiveRecord::RecordNotFound unless @inbox.active?
    end

    def mark_failed!(delivery, code)
      InboundEmailDelivery.transaction do
        current_delivery = @inbox.inbound_email_deliveries.lock.find(delivery.id)
        return current_delivery if current_delivery.processed?
        current_delivery.update!(
          status: :failed,
          failure_code: code,
          conversation: nil,
          conversation_message: nil,
          processed_at: Time.current
        )
        audit_failure!(current_delivery, code)
        current_delivery
      end
    end

    def audit_failure!(delivery, code)
      AuditEvent.record!(
        action: "email.intake_failed", source: :integration, workspace: @workspace,
        actor_kind: :system, subject: delivery, metadata: { failure_code: code }
      )
    end
end
