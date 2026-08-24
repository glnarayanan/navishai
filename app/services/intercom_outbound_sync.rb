class IntercomOutboundSync
  def self.enqueue!(workspace:, support_case:, membership:, operation_kind:, payload:)
    link = workspace.intercom_conversation_links.find_by(conversation_id: support_case.conversation_id)
    return unless link

    actor = workspace.memberships.find(membership.id)
    workspace.intercom_sync_operations.create!(
      intercom_connection: link.intercom_connection, intercom_conversation_link: link,
      membership: actor, user: actor.user, operation_kind: operation_kind, payload: payload
    ).tap do |operation|
      audit!("intercom.sync_enqueued", operation, actor: actor.user, operation_kind: operation.operation_kind)
    end
  end

  def self.deliver!(operation, client: nil)
    return unless operation

    current = claim!(operation)
    return current unless current&.sending?

    client ||= IntercomClient.new(connection: current.intercom_connection)
    result = dispatch!(current, client)
    complete!(current, result)
  rescue IntercomClient::ConfigurationError
    fail!(current || operation, "configuration_error")
  rescue IntercomClient::Rejected
    fail!(current || operation, "remote_rejected")
  rescue IntercomClient::Unavailable, ActiveRecord::ActiveRecordError, KeyError, ArgumentError
    fail!(current || operation, "outcome_unknown")
  end

  def self.retry!(connection:, client: IntercomClient.new(connection: connection), limit: 100)
    connection.intercom_sync_operations.retryable.order(:created_at, :id).limit(limit).map do |operation|
      deliver!(operation, client: client)
    end
  end

  def self.claim!(operation)
    operation.with_lock do
      retrying = operation.failed? && operation.attempt_count < IntercomSyncOperation::MAX_ATTEMPTS
      return operation unless operation.pending? || retrying

      operation.update!(
        status: :sending, failure_code: nil,
        attempt_count: operation.attempt_count + 1, last_attempted_at: Time.current
      )
      operation
    end
  end
  private_class_method :claim!

  def self.dispatch!(operation, client)
    link = operation.intercom_conversation_link
    payload = operation.payload
    actor_id = remote_admin_id!(client, operation.user.email_address)

    case operation.operation_kind
    when "note"
      client.add_note(conversation_id: link.remote_conversation_id, admin_id: actor_id, body: payload.fetch("body"))
    when "assign"
      assignee_id = payload["email"].present? ? remote_admin_id!(client, payload.fetch("email")) : "0"
      client.assign(
        conversation_id: link.remote_conversation_id, admin_id: actor_id, assignee_id: assignee_id
      )
    when "tag"
      tag_id = remote_tag_id!(operation, client)
      client.tag(conversation_id: link.remote_conversation_id, tag_id: tag_id, admin_id: actor_id)
    when "untag"
      mapping = operation.intercom_connection.intercom_tag_links.find_by(tag_id: payload.fetch("tag_id"))
      mapping ? client.untag(
        conversation_id: link.remote_conversation_id, tag_id: mapping.remote_tag_id, admin_id: actor_id
      ) : {}
    end
  end
  private_class_method :dispatch!

  def self.remote_admin_id!(client, email)
    admins = Array(client.admins["admins"])
    admin = admins.find { |candidate| candidate["email"].to_s.casecmp?(email.to_s) }
    raise IntercomClient::ConfigurationError, "No matching Intercom admin exists for #{email}" unless admin&.fetch("id", nil)

    admin.fetch("id").to_s
  end
  private_class_method :remote_admin_id!

  def self.remote_tag_id!(operation, client)
    connection = operation.intercom_connection
    payload = operation.payload
    mapping = connection.intercom_tag_links.find_by(tag_id: payload.fetch("tag_id"))
    return mapping.remote_tag_id if mapping

    response = client.create_tag(name: payload.fetch("name"))
    remote_id = response.fetch("id").to_s
    connection.intercom_tag_links.create!(
      workspace: operation.workspace, tag_id: payload.fetch("tag_id"), remote_tag_id: remote_id
    )
    remote_id
  end
  private_class_method :remote_tag_id!

  def self.complete!(operation, result)
    operation.with_lock do
      operation.update!(
        status: :completed, completed_at: Time.current,
        remote_object_id: result.is_a?(Hash) ? result["id"] : nil
      )
      audit!("intercom.sync_completed", operation, actor: operation.user, operation_kind: operation.operation_kind)
      operation
    end
  end
  private_class_method :complete!

  def self.fail!(operation, code)
    operation.with_lock do
      return operation unless operation.sending?

      operation.update!(status: code == "outcome_unknown" ? :unknown : :failed, failure_code: code)
      audit!(
        "intercom.sync_failed", operation, actor: operation.user,
        operation_kind: operation.operation_kind, failure_code: code
      )
      operation
    end
  end
  private_class_method :fail!

  def self.audit!(action, operation, actor:, **metadata)
    AuditEvent.record!(
      action: action, source: :integration, workspace: operation.workspace,
      actor: actor, subject: operation, metadata: metadata
    )
  end
  private_class_method :audit!
end
