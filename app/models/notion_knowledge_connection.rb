class NotionKnowledgeConnection < ApplicationRecord
  PAGE_ID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  belongs_to :workspace
  belongs_to :workspace_connector
  has_many :knowledge_sources, dependent: :restrict_with_exception
  has_many :knowledge_sync_passes, dependent: :restrict_with_exception
  validates :name, presence: true, length: { maximum: 100 }
  validate :valid_roots
  validate :notion_connector

  def ready?
    enabled? && workspace_connector.reload.enabled? && workspace_connector.service_token.present? &&
      !workspace.reload.deletion_requested?
  end

  private
    def valid_roots
      unless root_page_ids.is_a?(Array) && root_page_ids.size.in?(1..20) && root_page_ids.uniq == root_page_ids &&
        root_page_ids.all? { |id| id.is_a?(String) && id.match?(PAGE_ID) }
        errors.add(:root_page_ids, "must contain 1 to 20 unique Notion page IDs")
      end
    end

    def notion_connector
      errors.add(:workspace_connector, "must be this Workspace's Notion connector") unless
        workspace_connector&.workspace_id == workspace_id && workspace_connector&.provider == "notion"
    end
end
