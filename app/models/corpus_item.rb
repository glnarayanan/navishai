class CorpusItem < ApplicationRecord
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :source_snapshot
  validates :external_id, :title, :content, presence: true
  validates :external_id, length: { maximum: 255 }
  validates :title, length: { maximum: 500 }
  validates :content, length: { maximum: 100_000 }
  validate -> { errors.add(:context, "must be an object") unless context.is_a?(Hash) }

  def readonly?
    persisted?
  end
end
