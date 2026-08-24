class SharedEmailSmtpTransport
  class ConfigurationError < StandardError; end

  def deliver!(inbox:, message_id:, in_reply_to:, references:, to:, subject:, body:, attachments: [])
    settings = inbox.smtp_settings
    raise ConfigurationError, "SMTP is not configured" if settings[:address].blank? || settings[:port].blank?

    mail = Mail.new
    mail.from = inbox.email_address
    mail.to = to
    mail.subject = subject
    mail.message_id = message_id
    mail.in_reply_to = in_reply_to if in_reply_to
    mail.references = references if references.present?
    mail.content_type = "text/plain; charset=UTF-8"
    mail.body = body
    attachments.each do |attachment|
      mail.attachments[attachment.fetch(:filename)] = {
        mime_type: attachment.fetch(:content_type),
        content: attachment.fetch(:content)
      }
    end
    mail.delivery_method(:smtp, settings.merge(port: Integer(settings[:port]), enable_starttls_auto: true))
    mail.deliver!
    message_id
  rescue ArgumentError => error
    raise ConfigurationError, error.message
  end
end
