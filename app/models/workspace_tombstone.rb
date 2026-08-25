class WorkspaceTombstone < ApplicationRecord
  belongs_to :organization
  belongs_to :deleted_by, class_name: "User"

  validates :former_workspace_id, :workspace_slug, :requested_at, :deleted_at, presence: true
  validates :former_workspace_id, uniqueness: true
  validates :record_count, :attachment_count, :memory_count,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  def readonly?
    persisted?
  end
end
