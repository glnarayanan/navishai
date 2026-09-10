class KnowledgeSyncPass < ApplicationRecord
  belongs_to :workspace
  belongs_to :intercom_connection, optional: true
  belongs_to :notion_knowledge_connection, optional: true
  scope :unfinished, -> { where(completed_at: nil) }
end
