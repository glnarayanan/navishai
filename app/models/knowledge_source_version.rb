class KnowledgeSourceVersion < ApplicationRecord
  MAX_CONTENT_BYTES = 1.megabyte

  belongs_to :workspace
  belongs_to :knowledge_source
  belongs_to :stored_attachment, optional: true
  belongs_to :created_by_membership, class_name: "Membership", optional: true
  belongs_to :created_by_user, class_name: "User", optional: true

  validates :content, :content_sha256, :retrieved_at, presence: true
  validates :version_number, numericality: { only_integer: true, greater_than: 0 },
    uniqueness: { scope: :knowledge_source_id }
  validates :content_sha256, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :retrieved_from_url, length: { maximum: 2_048 }, allow_nil: true
  validate :content_size
  validate :actor_matches_membership
  validate :url_matches_source

  def readonly?
    persisted?
  end

  def stale?(at: Time.current)
    expires_at.present? && expires_at <= at
  end

  def citation_uri
    knowledge_source.citation_uri(self)
  end

  private
    def content_size
      errors.add(:content, "must be between 1 byte and 1 MiB") unless content.to_s.bytesize.in?(1..MAX_CONTENT_BYTES)
    end

    def actor_matches_membership
      return if created_by_membership.nil? && created_by_user.nil?

      errors.add(:created_by_user, "does not match membership") unless created_by_membership&.user == created_by_user
    end

    def url_matches_source
      errors.add(:retrieved_from_url, "is required for a URL source") if knowledge_source&.url? && retrieved_from_url.blank?
      errors.add(:retrieved_from_url, "is not allowed for this source") if knowledge_source && !knowledge_source.url? && retrieved_from_url.present?
    end
end
