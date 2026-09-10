class AttachmentIntake
  MAX_FILES = 5
  MAX_TOTAL_BYTES = 10.megabytes

  class InvalidAttachment < StandardError; end

  Prepared = Data.define(:blob, :filename, :byte_size, :content_sha256, :content_type, :scan_status, :scan_result_code, :scanned_at) do
    def purge!
      blob.purge
      blob.service.delete(blob.key)
    end
  end

  SIGNATURES = [
    [ "application/msword", "\xD0\xCF\x11\xE0\xA1\xB1\x1A\xE1".b ],
    [ "application/pdf", "%PDF-".b ],
    [ "image/png", "\x89PNG\r\n\x1A\n".b ],
    [ "image/jpeg", "\xFF\xD8\xFF".b ],
    [ "image/gif", "GIF87a".b ],
    [ "image/gif", "GIF89a".b ]
  ].freeze

  def self.prepare!(inputs, scanner: AttachmentScanner.default)
    inputs = Array(inputs).compact_blank
    raise InvalidAttachment, "Select at least one file." if inputs.empty?
    raise InvalidAttachment, "Select no more than #{MAX_FILES} files." if inputs.size > MAX_FILES

    total_bytes = 0
    prepared = []
    inputs.each do |input|
      data, filename = read_input(input)
      total_bytes += data.bytesize
      raise InvalidAttachment, "Attachments exceed the 10 MiB total limit." if total_bytes > MAX_TOTAL_BYTES

      prepared << prepare_data!(data, filename, scanner)
    end
    prepared
  rescue StandardError
    prepared&.each(&:purge!)
    raise
  end

  def self.persist!(workspace:, prepared:, source:, message: nil, draft: nil, membership: nil)
    prepared.map do |item|
      attachment = workspace.stored_attachments.create!(
        source: source,
        uploaded_by_membership: membership,
        uploaded_by_user: membership&.user,
        filename: item.filename,
        byte_size: item.byte_size,
        content_sha256: item.content_sha256,
        detected_content_type: item.content_type,
        scan_status: item.scan_status,
        scan_result_code: item.scan_result_code,
        scanned_at: item.scanned_at
      )
      attachment.file.attach(item.blob)
      workspace.conversation_message_attachments.create!(
        conversation: message.conversation,
        conversation_message: message,
        stored_attachment: attachment
      ) if message
      workspace.email_draft_attachments.create!(email_draft: draft, stored_attachment: attachment) if draft
      attachment
    end
  end

  def self.read_input(input)
    if input.respond_to?(:read)
      filename = input.respond_to?(:original_filename) ? input.original_filename : "attachment"
      data = input.read(StoredAttachment::MAX_BYTES + 1).to_s.b
    else
      filename, data = input.values_at(:filename, :data)
      data = data.to_s.b
    end
    raise InvalidAttachment, "#{safe_filename(filename)} is empty." if data.empty?
    raise InvalidAttachment, "#{safe_filename(filename)} exceeds the 5 MiB file limit." if data.bytesize > StoredAttachment::MAX_BYTES

    [ data, safe_filename(filename) ]
  end
  private_class_method :read_input

  def self.prepare_data!(data, filename, scanner)
    content_type = detected_content_type(data)
    scan = if content_type
      scan_with(scanner, data:, content_type:, filename:)
    else
      AttachmentScanner::Result.new(status: :infected, code: "unsupported_type")
    end
    status, scanned_at = case scan.status.to_sym
    when :clean then [ "available", Time.current ]
    when :infected then [ "rejected", Time.current ]
    else [ "quarantined", nil ]
    end
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(data), filename: filename,
      content_type: content_type || "application/octet-stream", identify: false
    )
    Prepared.new(
      blob: blob, filename: filename, byte_size: data.bytesize,
      content_sha256: Digest::SHA256.hexdigest(data),
      content_type: content_type || "application/octet-stream",
      scan_status: status, scan_result_code: scan.code.to_s, scanned_at: scanned_at
    )
  end
  private_class_method :prepare_data!

  def self.scan_with(scanner, data:, content_type:, filename:)
    result = scanner.scan(data: data, content_type: content_type, filename: filename)
    unless result.is_a?(AttachmentScanner::Result) && %i[clean infected unavailable].include?(result.status.to_sym) && result.code.present?
      raise ArgumentError, "invalid scanner result"
    end

    result
  rescue StandardError => error
    Rails.logger.error("Attachment scan failed closed: #{error.class}")
    AttachmentScanner::Result.new(status: :unavailable, code: "scanner_unavailable")
  end
  private_class_method :scan_with

  def self.detected_content_type(data)
    match = SIGNATURES.find { |(_, signature)| data.start_with?(signature) }
    return match.first if match

    return KnowledgeWordDocument::CONTENT_TYPE if KnowledgeWordDocument.document?(data)

    text = data.dup.force_encoding(Encoding::UTF_8)
    "text/plain" if text.valid_encoding? && !text.match?(/[\x00-\x08\x0B\x0C\x0E-\x1F]/)
  end
  private_class_method :detected_content_type

  def self.safe_filename(filename)
    File.basename(filename.to_s.encode("UTF-8", invalid: :replace, undef: :replace).tr("\u0000-\u001F", "")).presence&.truncate(255) || "attachment"
  end
  private_class_method :safe_filename
end
