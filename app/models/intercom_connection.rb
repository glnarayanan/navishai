class IntercomConnection < ApplicationRecord
  CREDENTIAL_KEY_FORMAT = /\A[a-z0-9_]+\z/

  belongs_to :workspace
  has_many :intercom_conversation_links, dependent: :restrict_with_exception
  has_many :intercom_part_links, dependent: :restrict_with_exception
  has_many :intercom_tag_links, dependent: :restrict_with_exception
  has_many :source_support_case_taggings, class_name: "SupportCaseTagging",
    foreign_key: :source_intercom_connection_id, dependent: :restrict_with_exception
  has_many :intercom_webhook_deliveries, dependent: :restrict_with_exception
  has_many :intercom_sync_operations, dependent: :restrict_with_exception
  has_many :intercom_outbound_deliveries, dependent: :restrict_with_exception
  has_many :intercom_backfill_manifests, dependent: :restrict_with_exception
  has_many :intercom_backfill_runs, dependent: :restrict_with_exception

  has_secure_token :webhook_key

  normalizes :name, with: ->(value) { value.strip }
  normalizes :remote_workspace_id, with: ->(value) { value.strip }
  normalizes :credential_key, with: ->(value) { value.strip.downcase }

  validates :name, :remote_workspace_id, presence: true, length: { maximum: 100 }
  validates :remote_workspace_id, uniqueness: { scope: :workspace_id }
  validates :webhook_key, presence: true, uniqueness: true
  validates :credential_key, presence: true, length: { maximum: 100 }, format: { with: CREDENTIAL_KEY_FORMAT }

  scope :active, -> { where(active: true) }

  def access_token
    credential(:access_token, "ACCESS_TOKEN")
  end

  def client_secret
    credential(:client_secret, "CLIENT_SECRET")
  end

  def ready?
    active? && access_token.present? && client_secret.to_s.bytesize >= 32
  end

  private
    def credential(name, suffix)
      stored = Rails.application.credentials.dig(:intercom, credential_key.to_sym, name)
      stored.presence || ENV["NAVISHAI_INTERCOM_#{credential_key.upcase}_#{suffix}"].presence
    end
end
