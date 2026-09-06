class KnowledgeSource < ApplicationRecord
  SOURCE_KINDS = %w[manual url upload intercom_help_center].freeze

  belongs_to :intercom_connection, optional: true
  has_one :knowledge_sync_observation, dependent: :restrict_with_exception
  has_one :knowledge_applicability, dependent: :restrict_with_exception

  belongs_to :workspace
  belongs_to :current_version, class_name: "KnowledgeSourceVersion", optional: true
  belongs_to :deleted_by_membership, class_name: "Membership", optional: true
  belongs_to :deleted_by_user, class_name: "User", optional: true
  has_many :versions, -> { order(version_number: :desc) },
    class_name: "KnowledgeSourceVersion", dependent: :restrict_with_exception

  enum :source_kind, SOURCE_KINDS.index_by(&:itself), validate: true

  validates :source_key, :title, presence: true
  validates :source_key, format: { with: /\A[0-9a-f-]{36}\z/ }, uniqueness: true
  validates :title, length: { maximum: 200 }
  validates :canonical_url, length: { maximum: 2_048 }, allow_nil: true
  validates :external_id, length: { maximum: 500 }, allow_nil: true
  validate :locator_matches_kind

  scope :active, -> { where(deleted_at: nil).where.not(id: KnowledgeSyncObservation.where.not(retired_at: nil).select(:knowledge_source_id)) }

  def deleted?
    deleted_at.present? || knowledge_sync_observation&.retired_at.present?
  end

  def stale?(at: Time.current)
    (knowledge_sync_observation&.unavailable_at.present? && knowledge_sync_observation.unavailable_at <= at) || current_version&.stale?(at: at) || false
  end

  def display_title
    current_version&.source_title.presence || title
  end

  def citation_uri(version = current_version)
    "knowledge://sources/#{source_key}/versions/#{version.version_number}"
  end

  private
    def locator_matches_kind
      errors.add(:canonical_url, "is required") if url? && canonical_url.blank?
      errors.add(:external_id, "is required") if intercom_help_center? && external_id.blank?
      errors.add(:canonical_url, "is not allowed") if !url? && canonical_url.present?
      errors.add(:external_id, "is not allowed") if !intercom_help_center? && external_id.present?
    end
end
