class OutboundWebhookDelivery < ApplicationRecord
  STATUSES = %w[pending sending delivered failed].freeze
  MAX_ATTEMPTS = 5

  belongs_to :workspace
  belongs_to :outbound_webhook_endpoint
  belongs_to :notification

  enum :status, STATUSES.index_by(&:itself), validate: true

  validates :event_key, presence: true, uniqueness: true,
    format: { with: /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/ }
  validates :payload_sha256, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :attempt_count, numericality: { only_integer: true, in: 0..MAX_ATTEMPTS }

  before_validation :freeze_payload, on: :create

  def signing_secret
    value = ENV["NAVISHAI_WEBHOOK_#{credential_key.upcase}_SIGNING_SECRET"] ||
      Rails.application.credentials.dig(:outbound_webhooks, credential_key.to_sym, :signing_secret)
    raise KeyError, "outbound webhook signing secret is not configured" if value.blank?

    value
  end

  private
    def freeze_payload
      return unless notification && workspace

      self.event_key ||= SecureRandom.uuid
      self.target_url ||= outbound_webhook_endpoint&.url
      self.credential_key ||= outbound_webhook_endpoint&.credential_key
      self.payload ||= JSON.generate(
        event_id: event_key, category: notification.category, title: notification.title,
        occurred_at: notification.occurred_at.iso8601(6), path: notification.path,
        workspace_key: workspace.runner_key
      )
      self.payload_sha256 ||= Digest::SHA256.hexdigest(payload.b)
    end
end
