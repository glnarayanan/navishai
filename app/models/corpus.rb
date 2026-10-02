class Corpus < ApplicationRecord
  belongs_to :workspace
  has_many :sources, dependent: :delete_all
  has_many :source_snapshots
  has_many :corpus_items
  has_many :corpus_analyses
  has_many :scenarios
  has_many :graders
  has_many :grader_versions
  has_many :eval_cases
  has_many :eval_suites
  has_many :calibration_sets
  has_many :evaluation_targets
  has_many :evaluation_runs
  normalizes :name, with: ->(name) { name.strip }
  validates :name, presence: true, length: { maximum: 100 }

  def current_items
    corpus_items.joins(source_snapshot: :source).where("sources.current_snapshot_id = source_snapshots.id AND sources.expires_at > ?", Time.current)
  end

  def evidence_items
    corpus_items.joins(source_snapshot: :source).where("sources.expires_at > ? AND (sources.current_snapshot_id = source_snapshots.id OR sources.kind = ?)", Time.current, "traces")
  end

  def eval_definitions_expired?
    sources.where("expires_at <= ?", Time.current).exists?
  end

  def authorize_writer!(membership, manage: false)
    membership.lock!
    allowed = manage ? membership.can_manage_work? : membership.can_write?
    raise Current::RoleAccessDenied unless membership.workspace_id == workspace_id && allowed
  end
end
