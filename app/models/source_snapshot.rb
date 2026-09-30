class SourceSnapshot < ApplicationRecord
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :source
  belongs_to :imported_by, class_name: "User"
  has_many :corpus_items, dependent: :delete_all
  validates :number, numericality: { only_integer: true, greater_than: 0 }
  validates :digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :redaction, inclusion: { in: %w[email none] }
  validates :processing_version, presence: true

  def readonly?
    persisted?
  end
end
