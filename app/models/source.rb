class Source < ApplicationRecord
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :current_snapshot, class_name: "SourceSnapshot", optional: true
  has_many :source_snapshots
  validates :name, presence: true, length: { maximum: 180 }, uniqueness: { scope: [ :corpus_id, :kind ] }
  validates :kind, inclusion: { in: %w[conversations document] }
  validates :expires_at, presence: true
end
