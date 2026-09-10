require "uri"

class KnowledgeIngestion
  class InvalidSource < StandardError; end

  def self.create!(workspace:, membership:, source_kind:, title:, content: nil, url: nil,
    external_id: nil, upload: nil, expires_at: nil, url_fetcher: KnowledgeUrlFetcher.new)
    new(workspace:, membership:, url_fetcher:).create!(
      source_kind:, title:, content:, url:, external_id:, upload:, expires_at:
    )
  end

  # Imports every supported document from one ZIP bundle as its own upload source.
  # Every entry is scanned and extracted first; the sources then commit together.
  def self.create_bundle!(workspace:, membership:, title:, upload:, expires_at: nil)
    new(workspace:, membership:).create_bundle!(title:, upload:, expires_at:)
  end

  def self.update!(workspace:, membership:, knowledge_source:, content: nil, upload: nil, expires_at: nil,
    url_fetcher: KnowledgeUrlFetcher.new)
    new(workspace:, membership:, url_fetcher:).update!(knowledge_source:, content:, upload:, expires_at:)
  end

  def self.ingest_integration!(workspace:, source_kind:, title:, content:, external_id:,
    source_updated_at:, retrieved_at: Time.current, expires_at: nil, intercom_connection: nil, notion_knowledge_connection: nil, retrieved_from_url: nil)
    new(workspace:).ingest_integration!(
      source_kind:, title:, content:, external_id:, source_updated_at:, retrieved_at:, expires_at:, intercom_connection:, notion_knowledge_connection:, retrieved_from_url:
    )
  end

  def initialize(workspace:, membership: nil, url_fetcher: KnowledgeUrlFetcher.new)
    @workspace = workspace
    @url_fetcher = url_fetcher
    @membership = membership && workspace.memberships.find(membership.id)
    raise Current::RoleAccessDenied if @membership && !@membership.can_manage_work?
  end

  def create!(source_kind:, title:, content:, url:, external_id:, upload:, expires_at:)
    kind = source_kind.to_s
    raise InvalidSource, "Choose a supported source type." unless KnowledgeSource::SOURCE_KINDS.include?(kind)

    locator = locator_for(kind:, url:, external_id:)
    fetched = fetch_url_if_needed(kind:, content:, url: locator[:canonical_url])
    prepared, normalized_content = prepare_content(kind:, content: fetched&.content || content, upload:)
    source = nil
    KnowledgeSource.transaction do
      lock_locator!(kind, locator)
      if locator.values.compact.any? && @workspace.knowledge_sources.exists?(
        source_kind: kind, **locator.compact
      )
        raise InvalidSource, "That source is already in this workspace."
      end
      source = @workspace.knowledge_sources.create!(
        source_kind: kind, source_key: SecureRandom.uuid, title: title,
        canonical_url: locator[:canonical_url], external_id: locator[:external_id]
      )
      audit!("knowledge.source_created", source)
      attachment = persist_attachment(prepared)
      append_version!(source:, content: normalized_content, stored_attachment: attachment,
        retrieved_at: fetched&.retrieved_at || Time.current,
        retrieved_from_url: fetched&.url || locator[:canonical_url],
        source_updated_at: fetched&.source_updated_at,
        expires_at: parse_expiry(expires_at))
    end
    prepared = nil
    source
  ensure
    Array(prepared).each(&:purge!)
  end

  def create_bundle!(title:, upload:, expires_at:)
    raise InvalidSource, "Choose a ZIP bundle to upload." unless upload
    archive = if upload.respond_to?(:read)
      upload.read(KnowledgeZipBundle::MAX_ARCHIVE_BYTES + 1).to_s.b
    else
      upload.to_h.fetch(:data).to_s.b
    end
    entries = KnowledgeZipBundle.entries(archive)
    expiry = parse_expiry(expires_at)
    prepared_entries = []
    entries.each do |entry|
      prepared, normalized_content = prepare_content(kind: "upload", content: nil, upload: { filename: entry.filename, data: entry.data })
      prepared_entries << [ entry.filename, prepared, normalized_content ]
    end
    sources = KnowledgeSource.transaction do
      prepared_entries.map do |filename, prepared, normalized_content|
        source = @workspace.knowledge_sources.create!(
          source_kind: :upload, source_key: SecureRandom.uuid,
          title: bundle_title(title, filename)
        )
        audit!("knowledge.source_created", source)
        attachment = persist_attachment(prepared)
        append_version!(source:, content: normalized_content, stored_attachment: attachment,
          retrieved_at: Time.current, expires_at: expiry)
        source
      end
    end
    prepared_entries = []
    sources
  rescue KnowledgeZipBundle::InvalidBundle => error
    raise InvalidSource, error.message
  ensure
    Array(prepared_entries).each { |(_, prepared, _)| Array(prepared).each(&:purge!) }
  end

  def update!(knowledge_source:, content:, upload:, expires_at:)
    source = @workspace.knowledge_sources.find(knowledge_source.id)
    fetched = fetch_url_if_needed(kind: source.source_kind, content:, url: source.canonical_url)
    prepared, normalized_content = prepare_content(
      kind: source.source_kind, content: fetched&.content || content, upload:
    )
    attachment_persisted = false
    KnowledgeSource.transaction do
      source.lock!
      raise InvalidSource, "Deleted sources cannot accept new versions." if source.deleted?
      expiry = parse_expiry(expires_at)
      retrieved_from_url = fetched&.url || source.canonical_url
      unless same_version?(source.current_version, normalized_content, expiry, fetched&.source_updated_at, retrieved_from_url)
        attachment = persist_attachment(prepared)
        attachment_persisted = attachment.present?
        append_version!(source:, content: normalized_content, stored_attachment: attachment,
          retrieved_at: fetched&.retrieved_at || Time.current,
          retrieved_from_url:,
          source_updated_at: fetched&.source_updated_at,
          expires_at: expiry)
      end
    end
    prepared = nil if attachment_persisted
    source
  ensure
    Array(prepared).each(&:purge!)
  end

  def ingest_integration!(source_kind:, title:, content:, external_id:, source_updated_at:, retrieved_at:, expires_at:, intercom_connection: nil, notion_knowledge_connection: nil, retrieved_from_url: nil)
    raise InvalidSource, "Choose a supported integration." unless %w[intercom_help_center notion_page].include?(source_kind.to_s)
    raise InvalidSource, "Add the Intercom article ID." if external_id.blank?

    connection = intercom_connection && @workspace.intercom_connections.find(intercom_connection.id)
    notion = notion_knowledge_connection && @workspace.notion_knowledge_connections.find(notion_knowledge_connection.id)
    raise InvalidSource, "Choose the correct source connection." if (connection && source_kind.to_s != "intercom_help_center") || (notion && source_kind.to_s != "notion_page")
    raise InvalidSource, "A Notion connection is required." if source_kind.to_s == "notion_page" && !notion
    retrieved_from_url = canonical_url(retrieved_from_url) if retrieved_from_url.present?
    normalized_content = normalize_content(content)
    source = nil
    KnowledgeSource.transaction do
      lock_locator!(source_kind.to_s, connection_id: connection&.id || notion&.id, external_id: external_id.to_s.strip)
      source = @workspace.knowledge_sources.lock.find_or_initialize_by(
        source_kind: source_kind.to_s, intercom_connection_id: connection&.id, notion_knowledge_connection_id: notion&.id, external_id: external_id.to_s.strip
      )
      if source.new_record?
        source.source_key = SecureRandom.uuid
        source.title = title
        source.save!
        audit!("knowledge.source_created", source)
      end
      raise InvalidSource, "Deleted sources cannot accept new versions." if source.deleted?
      append_version!(source:, content: normalized_content, retrieved_at:, source_updated_at:, expires_at:, retrieved_from_url:, source_title: (title if connection || notion))
    end
    source
  end

  def delete!(knowledge_source:)
    raise Current::RoleAccessDenied unless @membership

    source = @workspace.knowledge_sources.find(knowledge_source.id)
    KnowledgeSource.transaction do
      source.lock!
      return source if source.deleted?
      source.update!(
        deleted_at: Time.current,
        deleted_by_membership: @membership,
        deleted_by_user: @membership.user
      )
      audit!("knowledge.source_deleted", source)
    end
    source
  end

  private
    def prepare_content(kind:, content:, upload:)
      if kind == "upload"
        raise InvalidSource, "Choose a file to upload." unless upload
        prepared = AttachmentIntake.prepare!([ upload ])
        item = prepared.sole
        unless item.scan_status == "available"
          prepared.each(&:purge!)
          raise InvalidSource, "The uploaded file must pass the configured malware scan."
        end
        extracted = KnowledgeDocumentExtractor.extract(
          data: item.blob.download, content_type: item.content_type, filename: item.filename
        )

        [ prepared, normalize_content(extracted.text) ]
      else
        [ nil, normalize_content(content) ]
      end
    rescue AttachmentIntake::InvalidAttachment => error
      raise InvalidSource, error.message
    rescue KnowledgeDocumentExtractor::UnsupportedDocument => error
      Array(prepared).each(&:purge!)
      raise InvalidSource, error.message
    end

    def bundle_title(title, filename)
      base = title.to_s.strip
      name = File.basename(filename.to_s)
      value = base.present? ? "#{base}: #{name}" : name
      value.truncate(200)
    end

    def fetch_url_if_needed(kind:, content:, url:)
      @url_fetcher.fetch(url) if kind == "url" && content.blank?
    end

    def normalize_content(content)
      text = content.to_s.encode("UTF-8", invalid: :replace, undef: :replace).strip
      raise InvalidSource, "Add source content." if text.blank?
      raise InvalidSource, "Source content must be 1 MiB or less." if text.bytesize > KnowledgeSourceVersion::MAX_CONTENT_BYTES

      text
    end

    def locator_for(kind:, url:, external_id:)
      case kind
      when "url"
        { canonical_url: canonical_url(url), external_id: nil }
      when "intercom_help_center"
        value = external_id.to_s.strip
        raise InvalidSource, "Add the Intercom article ID." if value.blank?
        { canonical_url: nil, external_id: value }
      else
        { canonical_url: nil, external_id: nil }
      end
    end

    def canonical_url(value)
      KnowledgeUrlFetcher.normalize_url(value).to_s
    end

    def parse_expiry(value)
      return if value.blank?

      Time.zone.parse(value.to_s) || raise(InvalidSource, "Use a valid expiry date.")
    rescue ArgumentError
      raise InvalidSource, "Use a valid expiry date."
    end

    def persist_attachment(prepared)
      return unless prepared

      attachment = AttachmentIntake.persist!(
        workspace: @workspace, prepared:, source: :user_upload, membership: @membership
      ).sole
      AuditEvent.record!(
        action: "attachment.uploaded", source: :web, workspace: @workspace,
        actor: @membership.user, subject: attachment,
        metadata: { scan_status: attachment.scan_status }
      )
      attachment
    end

    def lock_locator!(kind, locator)
      value = locator.values.compact.join("|")
      return if value.blank?

      lock_key = "knowledge-source:#{@workspace.id}:#{kind}:#{value}"
      quoted_key = KnowledgeSource.connection.quote(lock_key)
      KnowledgeSource.connection.execute("SELECT pg_advisory_xact_lock(hashtext(#{quoted_key}))")
    end

    def append_version!(source:, content:, retrieved_at:, expires_at:, source_updated_at: nil,
      retrieved_from_url: nil, stored_attachment: nil, source_title: nil)
      if same_version?(source.current_version, content, expires_at, source_updated_at, retrieved_from_url) && source.current_version.source_title == source_title
        return source.current_version
      end

      digest = Digest::SHA256.hexdigest(content)
      version = source.versions.create!(
        workspace: @workspace,
        stored_attachment:,
        version_number: source.versions.maximum(:version_number).to_i + 1,
        content:, content_sha256: digest,
        retrieved_from_url:, retrieved_at:, source_updated_at:, expires_at:, source_title:,
        created_by_membership: @membership,
        created_by_user: @membership&.user
      )
      source.update!(current_version: version)
      audit!("knowledge.version_created", version)
      version
    end

    def same_version?(version, content, expires_at, source_updated_at, retrieved_from_url)
      version&.content_sha256 == Digest::SHA256.hexdigest(content) &&
        version.expires_at == expires_at &&
        version.source_updated_at == source_updated_at &&
        version.retrieved_from_url == retrieved_from_url
    end

    def audit!(action, subject)
      AuditEvent.record!(
        action:, source: @membership ? :web : :integration, workspace: @workspace,
        actor: @membership&.user, actor_kind: @membership ? :user : :system, subject:
      )
    end
end
