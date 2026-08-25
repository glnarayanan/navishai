class OutboundWebhookEndpoint < ApplicationRecord
  belongs_to :workspace
  has_many :outbound_webhook_deliveries, dependent: :restrict_with_exception

  normalizes :name, with: ->(value) { value.strip }
  normalizes :credential_key, with: ->(value) { value.strip.downcase }

  validates :name, presence: true, length: { maximum: 100 }, uniqueness: { scope: :workspace_id }
  validates :credential_key, presence: true, format: { with: /\A[a-z][a-z0-9_]{0,63}\z/ }
  validates :categories, length: { in: 1..Notification::CATEGORIES.length }
  validate :categories_are_allowed
  validate :url_is_public_https

  scope :active, -> { where(active: true) }

  private
    def categories_are_allowed
      errors.add(:categories, "contains an unsupported category") unless categories.is_a?(Array) &&
        categories.uniq.size == categories.size && (categories - Notification::CATEGORIES).empty?
    end

    def url_is_public_https
      GuardedWebFetcher.normalize_url(url)
    rescue GuardedWebFetcher::Error => error
      errors.add(:url, error.message)
    end
end
