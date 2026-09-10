class KnowledgeSyncObservation < ApplicationRecord
  belongs_to :workspace
  belongs_to :knowledge_source
  belongs_to :last_seen_pass, class_name: "KnowledgeSyncPass"
end
