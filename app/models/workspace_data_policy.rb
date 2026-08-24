class WorkspaceDataPolicy < ApplicationRecord
  CONTENT_RETENTION_OPTIONS = [ 30, 90, 180, 365, 730, 1825 ].freeze
  AUDIT_RETENTION_OPTIONS = [ 365, 730, 1825, 2555, 3650 ].freeze

  belongs_to :workspace

  validates :workspace_id, uniqueness: true
  validates :content_retention_days, inclusion: { in: CONTENT_RETENTION_OPTIONS }, allow_nil: true
  validates :audit_retention_days, inclusion: { in: AUDIT_RETENTION_OPTIONS }, allow_nil: true
  validate :audit_retention_covers_content

  def content_cutoff(at: Time.current)
    at - content_retention_days.days if content_retention_days
  end

  def audit_cutoff(at: Time.current)
    at - audit_retention_days.days if audit_retention_days
  end

  private
    def audit_retention_covers_content
      return unless content_retention_days && audit_retention_days
      return if audit_retention_days >= content_retention_days

      errors.add(:audit_retention_days, "must be at least as long as content retention")
    end
end
