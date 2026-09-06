class KnowledgeApplicability < ApplicationRecord
  belongs_to :workspace
  belongs_to :knowledge_source, optional: true
  belongs_to :intercom_connection, optional: true
  has_many :knowledge_applicability_products, dependent: :delete_all
  has_many :products, through: :knowledge_applicability_products
  has_many :knowledge_applicability_connections, dependent: :delete_all
  has_many :connections, through: :knowledge_applicability_connections, source: :intercom_connection

  validate :owner_in_workspace

  def audit_snapshot
    { all_products:, all_connections:, product_ids: product_ids.sort, connection_ids: connection_ids.sort }.to_json
  end

  private
    def owner_in_workspace
      owners = [ knowledge_source, intercom_connection ].compact
      errors.add(:base, "Choose one source or connection") unless owners.one?
      errors.add(:base, "Owner must belong to this Workspace") if owners.any? { |owner| owner.workspace_id != workspace_id }
    end
end
