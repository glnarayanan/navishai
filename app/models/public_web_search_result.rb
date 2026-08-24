require "uri"

class PublicWebSearchResult < ApplicationRecord
  attribute :citation_key, default: -> { SecureRandom.uuid }

  belongs_to :workspace
  belongs_to :public_web_search
  has_many :extractions, -> { order(created_at: :desc, id: :desc) },
    class_name: "PublicWebExtraction", dependent: :restrict_with_exception

  validates :rank, numericality: { only_integer: true, in: 1..10 }, uniqueness: { scope: :public_web_search_id }
  validates :citation_key, format: { with: RunnerProtocol::UUID_PATTERN }, uniqueness: true
  validates :title, presence: true, length: { maximum: 500 }
  validates :url, presence: true, length: { maximum: 2_048 }, uniqueness: { scope: :public_web_search_id }
  validates :excerpt, length: { maximum: 4_000 }
  validates :retrieved_at, presence: true
  validates :content_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validate :workspace_matches_search
  validate :safe_evidence_url

  def readonly?
    persisted?
  end

  private
    def workspace_matches_search
      errors.add(:workspace, "does not match the search") if public_web_search && public_web_search.workspace_id != workspace_id
    end

    def safe_evidence_url
      parsed = URI.parse(url.to_s)
      unless parsed.is_a?(URI::HTTPS) && parsed.host.present? && parsed.userinfo.nil? && parsed.fragment.nil?
        errors.add(:url, "must be an HTTPS evidence URL without credentials or a fragment")
      end
    rescue URI::InvalidURIError
      errors.add(:url, "must be a valid HTTPS evidence URL")
    end
end
