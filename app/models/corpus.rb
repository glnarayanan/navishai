class Corpus < ApplicationRecord
  belongs_to :workspace
  has_many :sources, dependent: :delete_all
  has_many :source_snapshots
  has_many :corpus_items
  has_many :corpus_analyses
  has_many :scenarios
  normalizes :name, with: ->(name) { name.strip }
  validates :name, presence: true, length: { maximum: 100 }

  def current_items
    corpus_items.joins(source_snapshot: :source).where("sources.current_snapshot_id = source_snapshots.id AND sources.expires_at > ?", Time.current)
  end

  def authorize_writer!(membership, manage: false)
    membership.lock!
    allowed = manage ? membership.can_manage_work? : membership.can_write?
    raise Current::RoleAccessDenied unless membership.workspace_id == workspace_id && allowed
  end
end
