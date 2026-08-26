class HumanIntercomSend
  DELIVERY_LOCK_NAMESPACE = 24_082_426

  def self.send!(workspace:, support_case:, membership:, body:, draft_version:, idempotency_key:, expected_source_part_id:, client: nil)
    new(
      workspace:, support_case:, membership:, body:, draft_version:, idempotency_key:,
      expected_source_part_id:, client:
    ).send!
  end

  def self.source_part_id(workspace:, support_case:)
    link = workspace.intercom_conversation_links.find_by!(conversation_id: support_case.conversation_id)
    latest_source_part(link).remote_part_id
  end

  def self.review_unknown!(workspace:, support_case:, membership:, delivery:, outcome:, remote_part_id: nil, client: nil)
    raise ArgumentError, "invalid delivery outcome" unless %w[accepted rejected].include?(outcome.to_s)

    terminal = IntercomOutboundDelivery.transaction do
      session = Session.active.lock.find(Current.session&.id)
      actor = workspace.memberships.lock.find(membership.id)
      raise Current::RoleAccessDenied unless actor.can_write? && actor.user == session.user
      current_case = workspace.support_cases.lock.find(support_case.id)
      current = workspace.intercom_outbound_deliveries.lock.find(delivery.id)
      raise ActiveRecord::RecordNotFound unless current.conversation_id == current_case.conversation_id
      raise ArgumentError, "the delivery attempt is still active" unless try_delivery_lock(current.id)
      if current.sending?
        current.update!(status: :unknown, failure_code: "unknown_outcome")
        audit_failure!(current)
        nil
      elsif current.sent? || current.failed?
        same = (outcome.to_s == "accepted" && current.sent?) ||
          (outcome.to_s == "rejected" && current.failed? && current.failure_code == "confirmed_not_sent")
        raise ArgumentError, "this delivery was already reviewed with the opposite outcome" unless same

        current
      end
    end
    return terminal if terminal

    current = workspace.intercom_outbound_deliveries.find(delivery.id)
    remote_part = if outcome.to_s == "accepted"
      raise ArgumentError, "add the Intercom conversation part ID" if remote_part_id.to_s.blank?

      remote = (client || IntercomClient.new(connection: current.intercom_connection)).conversation(current.remote_conversation_id)
      part_from(
        remote, remote_part_id: remote_part_id, admin_id: current.admin_id, body: current.body,
        expected_conversation_id: current.remote_conversation_id
      )
    end

    IntercomOutboundDelivery.transaction do
      session = Session.active.lock.find(Current.session&.id)
      actor = workspace.memberships.lock.find(membership.id)
      raise Current::RoleAccessDenied unless actor.can_write? && actor.user == session.user

      current_case = workspace.support_cases.lock.find(support_case.id)
      current = workspace.intercom_outbound_deliveries.lock.find(delivery.id)
      raise ActiveRecord::RecordNotFound unless current.conversation_id == current_case.conversation_id
      raise ArgumentError, "this delivery cannot be reviewed" unless current.unknown?

      if outcome.to_s == "accepted"
        complete_record!(current, remote_part, reviewer: actor)
      else
        current.update!(status: :failed, failure_code: "confirmed_not_sent")
        current.intercom_draft.update!(status: :ready)
      end
      AuditEvent.record!(
        action: "intercom.send_reviewed", source: :web, workspace: workspace,
        actor: actor.user, subject: current, metadata: { outcome: outcome.to_s }
      )
      current
    end
  end

  def initialize(workspace:, support_case:, membership:, body:, draft_version:, idempotency_key:, expected_source_part_id:, client:)
    @workspace = workspace
    @support_case = support_case
    @membership = membership
    @body = body
    @draft_version = draft_version.to_s
    @idempotency_key = idempotency_key.to_s
    @expected_source_part_id = expected_source_part_id.to_s
    @client = client
  end

  def send!
    attempted = false
    authorize_human!
    replay = replayed_delivery
    return replay if replay

    client = @client || IntercomClient.new(connection: connection)
    admin_id = resolve_admin_id!(client)
    acquire_conversation_lock!
    delivery, claimed = claim!(admin_id)
    return delivery unless claimed

    response = HumanSendAuthorization.with_current_authority(workspace: @workspace, membership: @membership) do
      attempted = true
      client.reply(
        conversation_id: delivery.remote_conversation_id,
        admin_id: delivery.admin_id,
        body: delivery.body
      )
    end
    remote_part = self.class.send(
      :part_from, response, admin_id: delivery.admin_id, body: delivery.body,
      after: delivery.started_at, expected_conversation_id: delivery.remote_conversation_id
    )
    complete!(delivery, remote_part)
  rescue Current::RoleAccessDenied, ActiveRecord::RecordNotFound
    if delivery
      attempted ? fail!(delivery, "unknown_outcome", retryable: false) :
        fail!(delivery, "authorization_changed", retryable: true)
    end
    raise
  rescue IntercomClient::ConfigurationError
    delivery ? fail!(delivery, "configuration_error", retryable: true) : raise
  rescue IntercomClient::Rejected
    delivery ? fail!(delivery, "remote_rejected", retryable: true) : raise
  rescue IntercomClient::Unavailable
    delivery && attempted ? fail!(delivery, "unknown_outcome", retryable: false) : raise
  rescue StandardError
    fail!(delivery, "unknown_outcome", retryable: false) if delivery && attempted
    raise
  ensure
    release_delivery_lock!
    release_conversation_lock!
  end

  private
    def authorize_human!
      Session.transaction do
        session = Session.active.lock.find(Current.session&.id)
        actor = @workspace.memberships.lock.find(@membership.id)
        raise Current::RoleAccessDenied unless actor.can_write? && actor.user == session.user
      end
    end

    def connection
      conversation_link.intercom_connection
    end

    def replayed_delivery
      raise ArgumentError, "idempotency key is required" if @idempotency_key.blank? || @idempotency_key.length > 100

      current_case = @workspace.support_cases.find(@support_case.id)
      existing = @workspace.intercom_outbound_deliveries.find_by(idempotency_key: @idempotency_key)
      return unless existing

      raise ActiveRecord::RecordNotFound unless existing.intercom_draft.support_case_id == current_case.id

      existing
    end

    def conversation_link
      @conversation_link ||= @workspace.intercom_conversation_links
        .includes(:intercom_connection).find_by!(conversation_id: @support_case.conversation_id)
    end

    def resolve_admin_id!(client)
      email = @membership.user.email_address.downcase
      admin = Array(client.admins["admins"]).find { |item| item["email"].to_s.downcase == email }
      raise IntercomClient::ConfigurationError, "No matching Intercom admin exists for #{email}" unless admin&.fetch("id", nil)

      admin.fetch("id").to_s
    end

    def claim!(admin_id)
      IntercomOutboundDelivery.transaction do
        raise ArgumentError, "idempotency key is required" if @idempotency_key.blank? || @idempotency_key.length > 100

        session = Session.active.lock.find(Current.session&.id)
        actor = @workspace.memberships.lock.find(@membership.id)
        raise Current::RoleAccessDenied unless actor.can_write? && actor.user == session.user
        current_case = @workspace.support_cases.lock.find(@support_case.id)
        existing = @workspace.intercom_outbound_deliveries.find_by(idempotency_key: @idempotency_key)
        if existing
          raise ActiveRecord::RecordNotFound unless existing.intercom_draft.support_case_id == current_case.id

          return [ existing, false ]
        end

        link = @workspace.intercom_conversation_links.lock.find_by!(conversation_id: current_case.conversation_id)
        raise ActiveRecord::RecordNotFound unless link.intercom_connection.active?
        source_part = self.class.send(:latest_source_part, link)
        unless source_part.remote_part_id == @expected_source_part_id
          raise ArgumentError, "The Intercom conversation changed. Review the latest messages before sending."
        end
        draft = IntercomDraftWorkflow.save!(
          workspace: @workspace, support_case: current_case, membership: actor,
          body: @body, expected_lock_version: @draft_version
        )
        draft.lock!
        raise ArgumentError, "draft is already being sent" unless draft.ready?

        delivery = @workspace.intercom_outbound_deliveries.create!(
          intercom_draft: draft, intercom_connection: link.intercom_connection,
          intercom_conversation_link: link, conversation: link.conversation,
          actor_membership: actor, actor_user: actor.user, idempotency_key: @idempotency_key,
          remote_conversation_id: link.remote_conversation_id, source_part_id: source_part.remote_part_id,
          admin_id: admin_id, body: draft.body,
          started_at: [ Time.current, link.conversation.last_message_at ].compact.max
        )
        draft.update!(status: :sending)
        AuditEvent.record!(action: "intercom.send_started", source: :web, workspace: @workspace, actor: actor.user, subject: delivery)
        acquire_delivery_lock!(delivery)
        [ delivery, true ]
      end
    end

    def complete!(delivery, remote_part)
      IntercomOutboundDelivery.transaction do
        current = @workspace.intercom_outbound_deliveries.lock.find(delivery.id)
        return current unless current.sending?

        self.class.send(:complete_record!, current, remote_part)
      end
    end

    def fail!(delivery, code, retryable:)
      IntercomOutboundDelivery.transaction do
        current = @workspace.intercom_outbound_deliveries.lock.find(delivery.id)
        return current unless current.sending?

        current.update!(status: retryable ? :failed : :unknown, failure_code: code)
        current.intercom_draft.update!(status: :ready) if retryable
        self.class.send(:audit_failure!, current)
        current
      end
    end

    def acquire_delivery_lock!(delivery)
      @locked_delivery_id = delivery.id
      IntercomOutboundDelivery.connection.raw_connection.exec_params(
        "SELECT pg_advisory_lock($1, $2)", [ DELIVERY_LOCK_NAMESPACE, Integer(delivery.id) ]
      )
    end

    def acquire_conversation_lock!
      @locked_conversation_link_id = conversation_link.id
      IntercomConversationLink.connection.raw_connection.exec_params(
        "SELECT pg_advisory_lock($1, $2)",
        [ IntercomConversationLink::REMOTE_WRITE_LOCK_NAMESPACE, Integer(@locked_conversation_link_id) ]
      )
    end

    def release_conversation_lock!
      return unless @locked_conversation_link_id

      IntercomConversationLink.connection.raw_connection.exec_params(
        "SELECT pg_advisory_unlock($1, $2)",
        [ IntercomConversationLink::REMOTE_WRITE_LOCK_NAMESPACE, Integer(@locked_conversation_link_id) ]
      )
      @locked_conversation_link_id = nil
    end

    def release_delivery_lock!
      return unless @locked_delivery_id

      IntercomOutboundDelivery.connection.raw_connection.exec_params(
        "SELECT pg_advisory_unlock($1, $2)", [ DELIVERY_LOCK_NAMESPACE, Integer(@locked_delivery_id) ]
      )
      @locked_delivery_id = nil
    end

    def self.latest_source_part(link)
      link.intercom_part_links.where.not(part_type: :note)
        .order(remote_created_at: :desc, id: :desc).first!
    end

    def self.part_from(remote, remote_part_id: nil, admin_id:, body:, after: nil, expected_conversation_id:)
      unless remote["id"].to_s == expected_conversation_id.to_s
        raise IntercomClient::Unavailable, "Intercom returned the wrong conversation"
      end

      parts = Array(remote.dig("conversation_parts", "conversation_parts"))
      part = if remote_part_id
        parts.find { |item| item["id"].to_s == remote_part_id.to_s }
      else
        parts.reject { |item| item["part_type"].to_s == "note" }
          .max_by { |item| [ item["created_at"].to_i, item["id"].to_s ] }
      end
      unless part && part["part_type"].to_s == "comment" && part.dig("author", "type").to_s == "admin" &&
          part.dig("author", "id").to_s == admin_id.to_s && remote_body(part["body"]) == normalized_body(body)
        raise IntercomClient::Unavailable, "Intercom did not return the accepted reply"
      end
      if after && Time.zone.at(part["created_at"].to_i) < after.change(usec: 0)
        raise IntercomClient::Unavailable, "Intercom did not return the accepted reply"
      end

      part
    end

    def self.complete_record!(delivery, part, reviewer: nil)
      existing_part = delivery.workspace.intercom_part_links.find_by(
        intercom_connection: delivery.intercom_connection, remote_part_id: part.fetch("id").to_s
      )
      if existing_part && existing_part.intercom_conversation_link != delivery.intercom_conversation_link
        raise ActiveRecord::RecordNotFound
      end
      message = existing_part&.conversation_message
      unless message
        occurred_at = [ Time.zone.at(part["created_at"].to_i), delivery.started_at ].max
        message = if reviewer
          ConversationThread.append_confirmed_outbound!(
            workspace: delivery.workspace, conversation: delivery.conversation,
            author_membership: delivery.actor_membership, reviewer_membership: reviewer,
            body: delivery.body, occurred_at: occurred_at, source: :web
          )
        else
          ConversationThread.append_outbound!(
            workspace: delivery.workspace, conversation: delivery.conversation,
            membership: delivery.actor_membership, body: delivery.body,
            occurred_at: occurred_at, source: :web
          )
        end
      end
      unless existing_part
        delivery.workspace.intercom_part_links.create!(
          intercom_connection: delivery.intercom_connection,
          intercom_conversation_link: delivery.intercom_conversation_link,
          conversation: delivery.conversation, conversation_message: message,
          remote_part_id: part.fetch("id").to_s, part_type: :admin_reply,
          author_name: part.dig("author", "name"), body: part["body"].to_s.presence || delivery.body,
          source_digest: Digest::SHA256.hexdigest(JSON.generate(part)),
          remote_created_at: Time.zone.at(part["created_at"].to_i)
        )
      end
      delivery.update!(
        status: :sent, failure_code: nil, conversation_message: message,
        remote_part_id: part.fetch("id").to_s, sent_at: [ message.occurred_at, delivery.started_at ].max
      )
      delivery.intercom_draft.update!(status: :sent)
      AuditEvent.record!(
        action: "intercom.send_succeeded", source: :web, workspace: delivery.workspace,
        actor: delivery.actor_user, subject: delivery
      )
      delivery
    end

    def self.audit_failure!(delivery)
      AuditEvent.record!(
        action: "intercom.send_failed", source: :web, workspace: delivery.workspace,
        actor: delivery.actor_user, subject: delivery, metadata: { failure_code: delivery.failure_code }
      )
    end

    def self.remote_body(value)
      marked = value.to_s
        .gsub(/<br\s*\/?\s*>/i, "\n")
        .gsub(%r{</(?:p|div|li)>}i, "\n")
      normalized_body(ActionView::Base.full_sanitizer.sanitize(marked))
    end

    def self.normalized_body(value)
      value.to_s.gsub("\r\n", "\n").strip
    end

    def self.try_delivery_lock(delivery_id)
      value = IntercomOutboundDelivery.connection.raw_connection.exec_params(
        "SELECT pg_try_advisory_xact_lock($1, $2)", [ DELIVERY_LOCK_NAMESPACE, Integer(delivery_id) ]
      ).getvalue(0, 0)
      ActiveModel::Type::Boolean.new.cast(value)
    end
end
