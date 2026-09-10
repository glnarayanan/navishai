class KnowledgeApplicabilityScope
  def initialize(workspace:, support_case: nil)
    @workspace = workspace
    @support_case = support_case
    raise ArgumentError, "Case must belong to this Workspace" if support_case && support_case.workspace_id != workspace.id
  end

  def sources
    relation = @workspace.knowledge_sources
    return relation unless @support_case

    connection_id = @support_case.intercom_conversation_link&.intercom_connection_id
    product_ids = @support_case.products.pluck(:id)
    if product_ids.empty? && connection_id
      defaults = KnowledgeApplicability.find_by(workspace: @workspace, intercom_connection_id: connection_id)
      product_ids = defaults.products.pluck(:id) if defaults && !defaults.all_products?
    end
    relation.joins(<<~SQL).where(<<~SQL, connection_id: connection_id, product_ids: product_ids)
      LEFT JOIN knowledge_applicabilities overrides
        ON overrides.knowledge_source_id = knowledge_sources.id
        AND overrides.workspace_id = knowledge_sources.workspace_id
      LEFT JOIN knowledge_applicabilities defaults
        ON defaults.intercom_connection_id = knowledge_sources.intercom_connection_id
        AND defaults.workspace_id = knowledge_sources.workspace_id
    SQL
      (
        COALESCE(overrides.all_products, defaults.all_products, TRUE)
        OR EXISTS (
          SELECT 1 FROM knowledge_applicability_products mappings
          WHERE mappings.knowledge_applicability_id = COALESCE(overrides.id, defaults.id)
            AND mappings.product_id IN (:product_ids)
        )
      ) AND (
        (COALESCE(overrides.id, defaults.id) IS NULL
          AND (knowledge_sources.intercom_connection_id IS NULL OR knowledge_sources.intercom_connection_id = :connection_id))
        OR COALESCE(overrides.all_connections, defaults.all_connections, FALSE)
        OR EXISTS (
          SELECT 1 FROM knowledge_applicability_connections mappings
          WHERE mappings.knowledge_applicability_id = COALESCE(overrides.id, defaults.id)
            AND mappings.intercom_connection_id = :connection_id
        )
      )
    SQL
  end

  def include?(source)
    sources.exists?(id: source.id)
  end
end
