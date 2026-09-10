class KnowledgeSyncPass < ApplicationRecord
  belongs_to :workspace
  belongs_to :intercom_connection
  scope :unfinished, -> { where(completed_at: nil) }
end
