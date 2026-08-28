class IntercomSync
  CONVERSATION_TOPICS = %w[
    conversation.user.created conversation.user.replied conversation.admin.single.created conversation.admin.replied
    conversation.admin.noted conversation.admin.assigned conversation.admin.open.assigned
    conversation.admin.opened conversation.admin.closed conversation.admin.snoozed
    conversation.admin.unsnoozed conversation.operator.replied conversation.priority.updated
    conversation.contact.attached conversation.contact.detached
    conversation.deleted conversation_part.redacted conversation_part.tag.created
  ].freeze
  CONTACT_TOPICS = %w[
    contact.archived contact.deleted contact.email.updated contact.lead.added_email
    contact.lead.created contact.lead.signed_up contact.lead.updated contact.merged
    contact.unarchive contact.user.created contact.user.updated
  ].freeze
  COMPANY_TOPICS = %w[company.created company.updated company.deleted company.contact.attached company.contact.detached].freeze
  SUPPORTED_TOPICS = (CONVERSATION_TOPICS + CONTACT_TOPICS + COMPANY_TOPICS + [ "ping" ]).freeze

  class InvalidPayload < StandardError; end
  class UnsupportedTopic < InvalidPayload; end
  class IdentityAmbiguous < StandardError; end

  def self.receive!(connection:, raw_payload:, received_at: Time.current, client: nil)
    new(connection:, client: client || IntercomClient.new(connection: connection)).receive!(raw_payload, received_at:)
  end

  def self.reconcile!(connection:, client: IntercomClient.new(connection: connection), limit: 500)
    new(connection:, client:).reconcile!(limit:)
  end

  def self.retry!(connection:, membership:, client: IntercomClient.new(connection: connection), limit: 100)
    new(connection:, client:).retry!(membership:, limit:)
  end

  def initialize(connection:, client:)
    @connection = connection
    @workspace = connection.workspace
    @client = client
  end

  def receive!(raw_payload, received_at:)
    payload = parse_payload(raw_payload)
    validate_notification!(payload)
    digest = Digest::SHA256.hexdigest(raw_payload)
    delivery = persist_delivery!(payload, raw_payload, digest, received_at)
    return delivery if delivery.processed?

    process_delivery!(delivery, payload)
  end

  def reconcile!(limit:)
    synced = 0
    cursor = @connection.reconciliation_cursor
    loop do
      response = @client.conversations(starting_after: cursor)
      conversations = Array(response["conversations"])
      processed_on_page = 0
      conversations.each do |summary|
        break if synced >= limit

        remote = @client.conversation(summary.fetch("id"))
        sync_conversation!(remote)
        synced += 1
        processed_on_page += 1
      end
      if synced >= limit
        cursor = next_cursor(response) if processed_on_page == conversations.size
        break
      end

      cursor = next_cursor(response)
      break unless cursor
    end
    @connection.update!(reconciliation_cursor: cursor, last_reconciled_at: Time.current, last_error_code: nil)
    synced
  rescue IntercomClient::Error
    @connection.update!(last_error_code: "remote_unavailable")
    raise
  rescue IdentityAmbiguous
    @connection.update!(last_error_code: "identity_ambiguous")
    raise
  end

  def retry!(membership:, limit:)
    actor = @workspace.memberships.find(membership.id)
    raise Current::RoleAccessDenied unless actor.can_configure_integrations?

    @connection.intercom_webhook_deliveries.retryable.order(:received_at, :id).limit(limit).map do |delivery|
      payload = parse_payload(delivery.raw_payload)
      process_delivery!(delivery, payload, retry_actor: actor.user)
    end
  end

  def sync_historical_conversation!(remote)
    existing = @connection.intercom_conversation_links.find_by(remote_conversation_id: remote.fetch("id").to_s)
    prior_digest = existing&.source_digest
    stale = existing && remote_time(remote["updated_at"] || remote["created_at"]) < existing.remote_updated_at
    link = sync_conversation!(remote)
    outcome = if existing.nil?
      :imported
    elsif stale
      :skipped
    elsif link.source_digest == prior_digest
      :matched
    else
      :imported
    end
    [ link, outcome ]
  end

  private
    def parse_payload(raw_payload)
      JSON.parse(raw_payload)
    rescue JSON::ParserError
      raise InvalidPayload, "invalid JSON"
    end

    def validate_notification!(payload)
      raise InvalidPayload, "invalid notification" unless payload.is_a?(Hash) && payload["type"] == "notification_event"
      raise InvalidPayload, "missing notification id" if payload["id"].to_s.blank?
      raise InvalidPayload, "wrong Intercom workspace" unless payload["app_id"].to_s == @connection.remote_workspace_id
      raise InvalidPayload, "missing topic" if payload["topic"].to_s.blank?
    end

    def persist_delivery!(payload, raw_payload, digest, received_at)
      existing = @connection.intercom_webhook_deliveries.find_by(notification_id: payload.fetch("id"))
      if existing
        raise InvalidPayload, "notification content changed" unless existing.content_sha256 == digest
        return existing
      end

      @connection.intercom_webhook_deliveries.create!(
        workspace: @workspace, notification_id: payload.fetch("id"), topic: payload.fetch("topic"),
        content_sha256: digest, raw_payload: raw_payload, received_at: received_at
      )
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    def process_delivery!(delivery, payload, retry_actor: nil)
      delivery.with_lock do
        return delivery if delivery.processed?

        @connection.lock!
        raise InvalidPayload, "Intercom connection is paused" unless @connection.active?

        audit!(
          "intercom.webhook_retried", delivery,
          delivery.failure_code ? { failure_code: delivery.failure_code } : {}, retry_actor: retry_actor
        ) if retry_actor
        delivery.update!(attempt_count: delivery.attempt_count + 1, last_attempted_at: Time.current)
        begin
          topic = payload.fetch("topic")
          raise UnsupportedTopic, "unsupported topic" unless SUPPORTED_TOPICS.include?(topic)

          item = payload.dig("data", "item") || {}
          if topic == "conversation.deleted"
            delete_conversation!(item)
          elsif topic == "conversation_part.redacted"
            redact_part!(item)
          elsif CONVERSATION_TOPICS.include?(topic)
            remote_id = conversation_id(item)
            remote = @client.conversation(remote_id)
            sync_conversation!(remote)
          elsif CONTACT_TOPICS.include?(topic)
            if %w[contact.archived contact.deleted].include?(topic)
              retire_identity!(:contact, item["id"])
            else
              result = sync_contact!(item, revive: topic == "contact.unarchive")
              raise IdentityAmbiguous unless result.matched?
              retire_identity!(:contact, item.dig("merged_from", "id")) if topic == "contact.merged"
            end
          elsif COMPANY_TOPICS.include?(topic)
            if topic == "company.deleted"
              retire_identity!(:account, item["id"])
            else
              raise IdentityAmbiguous unless sync_company!(item).matched?
            end
          end
          delivery.update!(status: :processed, processed_at: Time.current, failure_code: nil)
          audit!("intercom.webhook_processed", delivery)
        rescue IdentityAmbiguous
          delivery.update!(status: :failed, failure_code: "identity_ambiguous", processed_at: Time.current)
          audit!("intercom.webhook_failed", delivery, failure_code: "identity_ambiguous")
        end
        delivery
      end
    rescue UnsupportedTopic
      fail_delivery!(delivery, "unsupported_topic", retry_actor: retry_actor)
      raise
    rescue InvalidPayload
      fail_delivery!(delivery, "invalid_payload", retry_actor: retry_actor)
      raise
    rescue IntercomClient::Error
      fail_delivery!(delivery, "remote_unavailable", retry_actor: retry_actor)
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, ActiveRecord::StatementInvalid, ArgumentError
      fail_delivery!(delivery, "persistence_error", retry_actor: retry_actor)
    end

    def sync_conversation!(remote)
      raise InvalidPayload, "conversation missing id" if remote["id"].to_s.blank?

      updated_at = remote_time(remote["updated_at"] || remote["created_at"])
      digest = Digest::SHA256.hexdigest(JSON.generate(remote))
      link = @connection.intercom_conversation_links.find_by(remote_conversation_id: remote.fetch("id").to_s)
      return link if link && updated_at < link.remote_updated_at

      contact_data = Array(remote.dig("contacts", "contacts")).first || remote.dig("source", "author")
      contact_result = sync_contact!(contact_data || {})
      raise IdentityAmbiguous unless contact_result.matched?
      company_data = remote["company"] || Array(remote.dig("companies", "companies")).first
      if company_data
        account_result = sync_company!(company_data)
        raise IdentityAmbiguous unless account_result.matched?

        contact_result.record.update!(account: account_result.record)
      end

      IntercomConversationLink.transaction do
        if link
          link.lock_remote_sync!
          link.lock!
          return link if updated_at < link.remote_updated_at
        else
          source = remote["source"] || {}
          source_body = display_body(source["body"], fallback: "Intercom conversation received.")
          source_time = remote_time(source["created_at"] || remote["created_at"])
          message = if source.dig("author", "type") == "contact"
            ConversationThread.start_inbound!(
              workspace: @workspace, contact: contact_result.record,
              subject: remote["title"].to_s.squish.truncate(500).presence,
              body: source_body, occurred_at: source_time, source: :integration
            )
          else
            ConversationThread.start_external!(
              workspace: @workspace, contact: contact_result.record,
              subject: remote["title"].to_s.squish.truncate(500).presence,
              body: source_body, author_name: source.dig("author", "name"),
              occurred_at: source_time, source: :integration
            )
          end
          link = @connection.intercom_conversation_links.create!(
            workspace: @workspace, conversation: message.conversation,
            support_case: message.conversation.support_case, remote_conversation_id: remote.fetch("id").to_s,
            remote_state: remote["state"].to_s.presence || "open", source_digest: digest,
            remote_updated_at: updated_at, synced_at: Time.current
          )
          persist_part!(link, source.merge("id" => source["id"].presence || "conversation:#{remote.fetch('id')}", "part_type" => "contact_reply"), message: message)
        end

        sync_parts!(link, remote)
        sync_tags!(link, remote)
        assignee = remote_assignee(remote)
        link.update!(
          remote_state: remote["state"].to_s.presence || link.remote_state,
          remote_assignee_id: assignee&.fetch(:id), remote_assignee_name: assignee&.fetch(:name),
          source_digest: digest, remote_updated_at: updated_at, synced_at: Time.current
        )
        audit!("intercom.conversation_synced", link)
        link
      end
    end

    def sync_parts!(link, remote)
      parts = Array(remote.dig("conversation_parts", "conversation_parts"))
      parts.sort_by { |part| [ part["created_at"].to_i, part["id"].to_s ] }.each do |part|
        next if @connection.intercom_part_links.exists?(remote_part_id: part["id"].to_s)

        type = normalize_part_type(part)
        if type == "note"
          persist_part!(link, part, message: nil)
        elsif type == "contact_reply"
          message = ConversationThread.append_inbound!(
            workspace: @workspace, conversation: link.conversation, author: link.conversation.contact,
            body: display_body(part["body"], fallback: "Intercom reply received."),
            occurred_at: remote_time(part["created_at"]), source: :integration
          )
          persist_part!(link, part, message: message)
        elsif type == "admin_reply"
          message = append_external_reply!(link, part)
          persist_part!(link, part, message: message)
        end
      end
    end

    def redact_part!(item)
      remote_part_id = item["id"].to_s
      raise InvalidPayload, "conversation part missing id" if remote_part_id.blank?

      part = @connection.intercom_part_links.find_by(remote_part_id: remote_part_id)
      part&.update!(redacted_at: remote_time(item["updated_at"] || Time.current.to_i))
    end

    def delete_conversation!(item)
      remote_id = item["id"].to_s
      raise InvalidPayload, "conversation missing id" if remote_id.blank?

      link = @connection.intercom_conversation_links.find_by(remote_conversation_id: remote_id)
      link&.update!(remote_state: "deleted", remote_updated_at: Time.current, synced_at: Time.current)
    end

    def append_external_reply!(link, part)
      author = part.dig("author", "name").to_s.presence || "Intercom teammate"
      message = @workspace.conversation_messages.create!(
        conversation: link.conversation, direction: :outbound, author_kind: :external,
        external_author_name: author, body: display_body(part["body"], fallback: "Intercom reply sent."),
        occurred_at: remote_time(part["created_at"])
      )
      link.conversation.update!(last_message_at: [ link.conversation.last_message_at, message.occurred_at ].compact.max)
      SlaEngine.record_first_response!(
        workspace: @workspace, support_case: link.support_case, message: message
      ) if link.support_case.case_sla
      audit!("conversation.message_added", message, direction: "outbound", author_kind: "external")
      message
    end

    def persist_part!(link, part, message:)
      body = part["body"].to_s
      @connection.intercom_part_links.create!(
        workspace: @workspace, intercom_conversation_link: link, conversation: link.conversation,
        conversation_message: message, remote_part_id: part.fetch("id").to_s,
        part_type: normalize_part_type(part), author_name: part.dig("author", "name"), body: body.presence || "No content",
        source_digest: Digest::SHA256.hexdigest(JSON.generate(part)),
        remote_created_at: remote_time(part["created_at"]),
        redacted_at: (remote_time(part["updated_at"] || part["created_at"]) if part["redacted"] == true)
      )
    end

    def sync_tags!(link, remote)
      remote_tags = Array(remote.dig("tags", "tags"))
      desired = remote_tags.filter_map do |remote_tag|
        next if remote_tag["id"].to_s.blank? || remote_tag["name"].to_s.blank?

        mapping = @connection.intercom_tag_links.find_or_initialize_by(remote_tag_id: remote_tag.fetch("id").to_s)
        unless mapping.persisted?
          tag = @workspace.tags.where("lower(name) = ?", remote_tag.fetch("name").to_s.strip.downcase).first ||
            @workspace.tags.create!(name: remote_tag.fetch("name").to_s.strip.truncate(100))
          mapping.update!(workspace: @workspace, tag: tag)
        end
        mapping.tag
      end
      desired_ids = desired.map(&:id)
      desired_ids.each do |tag_id|
        @workspace.support_case_taggings.create_with(source_intercom_connection: @connection)
          .find_or_create_by!(support_case: link.support_case, tag_id: tag_id)
      end
      link.support_case.support_case_taggings
        .where(source_intercom_connection: @connection)
        .where.not(tag_id: desired_ids)
        .destroy_all
    end

    def sync_contact!(item, revive: false)
      resolve_identity!(
        :contact, item, keys: contact_keys(item),
        attributes: { name: item["name"].to_s.strip.presence }, revive: revive
      )
    end

    def sync_company!(item)
      keys = {}
      domain = item["website"].to_s.sub(%r{\Ahttps?://}i, "").split("/").first
      keys[:domain] = domain if domain.present?
      resolve_identity!(
        :account, item, keys: keys,
        attributes: { name: item["name"].to_s.strip.presence || "Intercom company" }
      )
    end

    def resolve_identity!(kind, item, keys:, attributes:, revive: false)
      id = item["id"].to_s
      raise InvalidPayload, "#{kind} missing id" if id.blank?
      namespace = "intercom:#{@connection.id}"
      existing = @workspace.source_identities.find_by(source_namespace: namespace, source_record_type: kind, source_record_id: id)
      if existing
        existing.update!(retired_at: nil) if revive && existing.retired_at?
        existing.replace_keys!(keys)
        existing.direct_record&.update!(attributes.compact)
        return SourceIdentityResolver::Result.new(status: existing.status.to_sym, source_identity: existing, record: existing.canonical_record)
      end
      return SourceIdentityResolver.resolve!(
        workspace: @workspace, entity_kind: kind, source_namespace: namespace,
        source_record_type: kind, source_record_id: id, keys: keys, attributes: attributes
      ) if keys.present?

      create_keyless_identity!(kind, namespace, id, attributes)
    end

    def create_keyless_identity!(kind, namespace, id, attributes)
      SourceIdentity.transaction do
        CustomerIdentityGraph.lock!(@workspace)
        record = (kind == :contact ? @workspace.contacts : @workspace.accounts).create!(attributes)
        identity = @workspace.source_identities.create!(
          entity_kind: kind, source_namespace: namespace, source_record_type: kind, source_record_id: id,
          status: :matched, resolution_method: :created, resolved_at: Time.current,
          contact: (record if kind == :contact), account: (record if kind == :account)
        )
        audit!("#{kind}.created", record)
        audit!("source_identity.matched", identity, entity_kind: kind.to_s, resolution_method: "created")
        SourceIdentityResolver::Result.new(status: :matched, source_identity: identity, record: record)
      end
    end

    def contact_keys(item)
      email = item["email"].to_s.strip
      email.present? ? { email: email } : {}
    end

    def retire_identity!(kind, source_id)
      return if source_id.to_s.blank?

      identity = @workspace.source_identities.find_by(
        source_namespace: "intercom:#{@connection.id}", source_record_type: kind,
        source_record_id: source_id.to_s
      )
      return unless identity && !identity.retired_at?

      identity.update!(retired_at: Time.current)
      identity.replace_keys!({})
      audit!("intercom.identity_retired", identity, entity_kind: kind.to_s)
    end

    def normalize_part_type(part)
      type = part["part_type"].to_s
      return "contact_reply" if type == "contact_reply"
      return "note" if type == "note"
      return "contact_reply" if part.dig("author", "type") == "contact"

      "admin_reply"
    end

    def remote_assignee(remote)
      admin_id = assigned_id(remote["admin_assignee_id"])
      if admin_id
        admin = intercom_admins.find { |candidate| candidate["id"].to_s == admin_id }
        return { id: admin_id, name: admin&.fetch("name", nil).presence || "Intercom admin #{admin_id}" }
      end

      team_id = assigned_id(remote["team_assignee_id"])
      return unless team_id

      team = intercom_teams.find { |candidate| candidate["id"].to_s == team_id }
      { id: team_id, name: team&.fetch("name", nil).presence || "Intercom team #{team_id}" }
    end

    def assigned_id(value)
      value.to_s.presence unless value.to_s == "0"
    end

    def display_body(value, fallback:)
      ActionView::Base.full_sanitizer.sanitize(value.to_s).squish.presence || fallback
    end

    def intercom_admins
      @intercom_admins ||= Array(@client.admins["admins"])
    end

    def intercom_teams
      @intercom_teams ||= Array(@client.teams["teams"])
    end

    def next_cursor(response)
      value = response.dig("pages", "next")
      return value["starting_after"].presence if value.is_a?(Hash)
      return if value.blank?

      URI.decode_www_form(URI(value.to_s).query.to_s).to_h["starting_after"].presence
    rescue URI::InvalidURIError
      raise IntercomClient::Unavailable, "Intercom returned an invalid pagination cursor"
    end

    def conversation_id(item)
      item["conversation_id"].presence || item["id"].presence || item.dig("conversation", "id") ||
        raise(InvalidPayload, "conversation missing id")
    end

    def remote_time(value)
      Time.zone.at(Integer(value || Time.current.to_i))
    end

    def fail_delivery!(delivery, code, retry_actor: nil)
      delivery.with_lock do
        retry_metadata = delivery.failure_code ? { failure_code: delivery.failure_code } : {}
        audit!("intercom.webhook_retried", delivery, retry_metadata, retry_actor: retry_actor) if retry_actor
        delivery.update!(
          status: :failed, failure_code: code, processed_at: Time.current,
          attempt_count: delivery.attempt_count + 1, last_attempted_at: Time.current
        )
        audit!("intercom.webhook_failed", delivery, failure_code: code)
      end
      delivery
    end

    def audit!(action, subject, metadata = nil, retry_actor: nil, **values)
      metadata = (metadata || {}).merge(values)
      AuditEvent.record!(
        action: action, source: :integration, workspace: @workspace,
        actor: retry_actor, actor_kind: (retry_actor ? nil : :system), subject: subject, metadata: metadata
      )
    end
end
