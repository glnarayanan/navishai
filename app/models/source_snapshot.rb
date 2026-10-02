class SourceSnapshot < ApplicationRecord
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :source
  belongs_to :imported_by, class_name: "User"
  has_many :corpus_items, dependent: :delete_all
  validates :number, numericality: { only_integer: true, greater_than: 0 }
  validates :digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :redaction, inclusion: { in: %w[email none exact] }
  validates :mask_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :mask_count, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 50 }, if: -> { redaction == "exact" }
  validates :mask_count, inclusion: { in: [ 0 ] }, unless: -> { redaction == "exact" }
  validates :mask_digest, inclusion: { in: [ Digest::SHA256.hexdigest("[]") ] }, unless: -> { redaction == "exact" }
  validates :mask_digest, exclusion: { in: [ Digest::SHA256.hexdigest("[]") ] }, if: -> { redaction == "exact" }
  validates :processing_version, presence: true

  def readonly?
    persisted?
  end
end
