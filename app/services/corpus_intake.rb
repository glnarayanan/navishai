class CorpusIntake
  class Invalid < StandardError; end
  MAX_BYTES = 10.megabytes
  MAX_ITEMS = 2_000
  PROCESSING_VERSION = "support-export-v1"

  def self.call(corpus:, membership:, name:, kind:, bytes:, redaction: "email", retention_days: 365, redaction_values: "")
    raise Invalid, "Choose conversations, document or traces." unless %w[conversations document traces].include?(kind)
    raise Invalid, "Choose email masking, exact text or original text." unless %w[email none exact].include?(redaction)
    raise Invalid, "Retention must be 1–3650 days." unless retention_days.to_s.match?(/\A[0-9]+\z/) && retention_days.to_i.between?(1, 3650)
    values = mask_values(redaction_values, redaction:)
    mask_digest = Digest::SHA256.hexdigest(JSON.generate(values))
    pattern = redaction == "email" ? /[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}/i : Regexp.union(values.sort_by { |value| [ -value.length, value ] })
    text = bytes.dup.force_encoding(Encoding::UTF_8)
    raise Invalid, "Upload valid UTF-8 text, at most 10 MiB, without null bytes." if text.bytesize > MAX_BYTES || !text.valid_encoding? || text.include?("\0")
    records = case kind
    when "document" then [ { "id" => "document", "title" => name, "content" => text, "context" => {} } ]
    when "traces" then SupportTrace.records(text)
    else conversations(text)
    end
    raise Invalid, "An upload needs 1–2000 records with unique IDs." unless records.size.between?(1, MAX_ITEMS) && records.map { |record| record["id"].to_s }.uniq.size == records.size
    records = records.map do |record|
      unless record["id"].is_a?(String) || record["id"].is_a?(Integer)
        raise Invalid, "Each record needs a string or integer ID."
      end
      unless record["title"].is_a?(String) && record["content"].is_a?(String) && record.fetch("context", {}).is_a?(Hash)
        raise Invalid, "Each record needs a string title, string content and an object context."
      end
      raise Invalid, "Source text must not contain null bytes." if record.to_json.include?("\\u0000")
      fields = { external_id: record.fetch("id").to_s, title: record.fetch("title"),
        content: record.fetch("content"), context: record.fetch("context", {}) }
      unless redaction == "none"
        fields = redact(fields, pattern:, redaction:)
        fields[:external_id] = "record-#{Digest::SHA256.hexdigest(record.fetch('id').to_s)}" if fields[:external_id] != record.fetch("id").to_s
      end
      SupportTrace.validate!(fields[:context].fetch("support_trace")) if kind == "traces"
      fields
    end
    raise Invalid, "Masking would merge distinct record IDs. Rename those IDs before upload; no records were imported." unless records.map { |record| record[:external_id] }.uniq.size == records.size
    processing_version = kind == "traces" ? SupportTrace::VERSION : PROCESSING_VERSION

    corpus.with_lock do
      corpus.authorize_writer!(membership)
      source = corpus.sources.find_or_initialize_by(name: name.to_s.strip, kind:)
      source.workspace = corpus.workspace
      source.expires_at = retention_days.to_i.days.from_now
      source.save!
      digest = Digest::SHA256.hexdigest(bytes)
      snapshot = source.source_snapshots.find_by(digest:, redaction:, processing_version:, mask_digest:)
      unless snapshot
        snapshot = source.source_snapshots.create!(workspace: corpus.workspace, corpus:,
          number: (source.source_snapshots.maximum(:number) || 0) + 1, digest:, redaction:,
          processing_version:, mask_digest:, mask_count: values.size, imported_by: membership.user, created_at: Time.current)
        records.each_slice(1_000) do |batch|
          rows = batch.map do |fields|
            item = CorpusItem.new(fields.merge(workspace: corpus.workspace, corpus:, source_snapshot: snapshot, created_at: Time.current))
            item.validate!
            item.attributes.except("id").merge("created_at" => item.created_at.iso8601(6))
          end
          # Keep the entire batch in a filtered bind, never in logged SQL literals.
          bind = ActiveRecord::Relation::QueryAttribute.new("content", JSON.generate(rows), CorpusItem.type_for_attribute("content"))
          CorpusItem.connection.exec_insert(<<~SQL, "CorpusItem Create", [ bind ])
            INSERT INTO "corpus_items" (workspace_id, corpus_id, source_snapshot_id, external_id, title, content, context, created_at)
            SELECT workspace_id, corpus_id, source_snapshot_id, external_id, title, content, context, created_at
            FROM jsonb_to_recordset($1::jsonb) AS records(workspace_id bigint, corpus_id bigint, source_snapshot_id bigint,
              external_id text, title text, content text, context jsonb, created_at timestamp)
          SQL
        end
      end
      source.update!(current_snapshot: snapshot)
      AuditEvent.record!(action: "corpus.imported", source: :web, workspace: corpus.workspace,
        actor: membership.user, subject: corpus, metadata: { record_count: records.size })
      snapshot
    end
  rescue JSON::ParserError, KeyError, TypeError
    raise Invalid, "Use a supported conversation export or support-trace-v1 array. Check the source type and required fields."
  end

  def self.conversations(text)
    data = JSON.parse(text)
    if data.is_a?(Array)
      data.map do |record|
        raise Invalid, "Each record must be an object." unless record.is_a?(Hash)
        record.slice("id", "title", "content", "context")
      end
    elsif data.is_a?(Hash) && data["tickets"].is_a?(Array)
      data["tickets"].map do |ticket|
        raise Invalid, "Each ticket must have a comments array of objects with text bodies." unless ticket.is_a?(Hash) && ticket.fetch("comments", []).is_a?(Array) && ticket.fetch("comments", []).all? { |comment| comment.is_a?(Hash) && comment["body"].is_a?(String) }
        raise Invalid, "Ticket descriptions must be text." unless ticket["description"].nil? || ticket["description"].is_a?(String)
        { "id" => ticket.fetch("id"), "title" => ticket.fetch("subject"),
          "content" => [ ticket["description"], *ticket.fetch("comments", []).map { |comment| comment.fetch("body") } ].compact.join("\n\n"), "context" => {} }
      end
    elsif data.is_a?(Hash) && data["conversations"].is_a?(Array)
      data["conversations"].map do |conversation|
        raise Invalid, "Each conversation needs source and conversation_parts objects." unless conversation.is_a?(Hash) && conversation.fetch("source", {}).is_a?(Hash) && conversation.fetch("conversation_parts", {}).is_a?(Hash)
        parts = conversation.fetch("conversation_parts", {}).fetch("conversation_parts", [])
        body = conversation.fetch("source", {}).fetch("body", nil)
        raise Invalid, "Conversation bodies must be text and parts must be an array of text bodies." unless (body.nil? || body.is_a?(String)) && parts.is_a?(Array) && parts.all? { |part| part.is_a?(Hash) && (part["body"].nil? || part["body"].is_a?(String)) }
        body = [ body, *parts.map { |part| part["body"] } ].compact.join("\n\n")
        { "id" => conversation.fetch("id"), "title" => conversation.fetch("title", "Conversation #{conversation.fetch('id')}"),
          "content" => body, "context" => {} }
      end
    else
      raise Invalid, "Use a JSON array, Zendesk tickets with comments, or Intercom conversations with parts."
    end
  end
  private_class_method :conversations

  def self.mask_values(text, redaction:)
    raise Invalid, "Exact text needs valid UTF-8, at most 8 KiB, without null bytes." unless text.is_a?(String)
    text = text.dup.force_encoding(Encoding::UTF_8)
    raise Invalid, "Exact text needs valid UTF-8, at most 8 KiB, without null bytes." if text.bytesize > 8.kilobytes || !text.valid_encoding? || text.include?("\0")
    values = text.split(/\r?\n/).reject(&:empty?).uniq.sort
    if redaction == "exact"
      raise Invalid, "Exact text needs 1–50 unique values, one per line, each 3–200 characters and not blank. Re-enter the values before retrying." unless values.size.between?(1, 50) && values.all? { |value| value.length.between?(3, 200) && value.present? }
    elsif values.any?
      raise Invalid, "Choose Mask exact text to apply the entered values; no records were imported. Re-enter the values before retrying."
    end
    values
  end
  private_class_method :mask_values

  def self.redact(value, pattern:, redaction:)
    case value
    when String then value.gsub(pattern, redaction == "email" ? "[email redacted]" : "[text redacted]")
    when Hash
      value.each_with_object({}) do |(key, child), masked|
        masked_key = key.is_a?(String) ? redact(key, pattern:, redaction:) : key
        raise Invalid, "#{redaction == 'email' ? 'Email' : 'Exact-text'} masking would merge distinct JSON keys. Rename those keys before upload; no records were imported." if masked.key?(masked_key)
        masked[masked_key] = redact(child, pattern:, redaction:)
      end
    when Array then value.map { |child| redact(child, pattern:, redaction:) }
    else value
    end
  end
  private_class_method :redact
end
