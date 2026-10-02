class CorpusIntake
  class Invalid < StandardError; end
  MAX_BYTES = 10.megabytes
  MAX_ITEMS = 2_000
  PROCESSING_VERSION = "support-export-v1"

  def self.call(corpus:, membership:, name:, kind:, bytes:, redaction: "email", retention_days: 365)
    raise Invalid, "Choose conversations or document." unless %w[conversations document].include?(kind)
    raise Invalid, "Choose email redaction or none." unless %w[email none].include?(redaction)
    raise Invalid, "Retention must be 1–3650 days." unless retention_days.to_s.match?(/\A[0-9]+\z/) && retention_days.to_i.between?(1, 3650)
    text = bytes.dup.force_encoding(Encoding::UTF_8)
    raise Invalid, "Upload valid UTF-8 text, at most 10 MiB, without null bytes." if text.bytesize > MAX_BYTES || !text.valid_encoding? || text.include?("\0")
    records = kind == "document" ? [ { "id" => "document", "title" => name, "content" => text, "context" => {} } ] : conversations(text)
    raise Invalid, "An upload needs 1–2000 records with unique IDs." unless records.size.between?(1, MAX_ITEMS) && records.map { |record| record["id"].to_s }.uniq.size == records.size
    records.each do |record|
      unless record["id"].is_a?(String) || record["id"].is_a?(Integer)
        raise Invalid, "Each record needs a string or integer ID."
      end
      unless record["title"].is_a?(String) && record["content"].is_a?(String) && record.fetch("context", {}).is_a?(Hash)
        raise Invalid, "Each record needs a string title, string content and an object context."
      end
      raise Invalid, "Source text must not contain null bytes." if record.to_json.include?("\\u0000")
    end

    corpus.with_lock do
      corpus.authorize_writer!(membership)
      source = corpus.sources.find_or_initialize_by(name: name.to_s.strip, kind:)
      source.workspace = corpus.workspace
      source.expires_at = retention_days.to_i.days.from_now
      source.save!
      digest = Digest::SHA256.hexdigest(bytes)
      snapshot = source.source_snapshots.find_by(digest:, redaction:)
      unless snapshot
        snapshot = source.source_snapshots.create!(workspace: corpus.workspace, corpus:,
          number: (source.source_snapshots.maximum(:number) || 0) + 1, digest:, redaction:,
          processing_version: PROCESSING_VERSION, imported_by: membership.user, created_at: Time.current)
        records.each do |record|
          fields = { external_id: record.fetch("id").to_s, title: record.fetch("title"),
            content: record.fetch("content"), context: record.fetch("context", {}) }
          if redaction == "email"
            fields = redact(fields)
            fields[:external_id] = "record-#{Digest::SHA256.hexdigest(record.fetch('id').to_s)}" if fields[:external_id] != record.fetch("id").to_s
          end
          snapshot.corpus_items.create!(fields.merge(workspace: corpus.workspace, corpus:, created_at: Time.current))
        end
      end
      source.update!(current_snapshot: snapshot)
      AuditEvent.record!(action: "corpus.imported", source: :web, workspace: corpus.workspace,
        actor: membership.user, subject: corpus, metadata: { record_count: records.size })
      snapshot
    end
  rescue JSON::ParserError, KeyError, TypeError
    raise Invalid, "Use a supported conversation export with id, title and content for each record."
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

  def self.redact(value)
    case value
    when String then value.gsub(/[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}/i, "[email redacted]")
    when Hash then value.to_h { |key, child| [ key.is_a?(String) ? redact(key) : key, redact(child) ] }
    when Array then value.map { |child| redact(child) }
    else value
    end
  end
  private_class_method :redact
end
