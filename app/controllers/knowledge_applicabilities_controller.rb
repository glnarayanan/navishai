class KnowledgeApplicabilitiesController < ApplicationController
  include WorkspaceAuthorization
  before_action :require_workspace
  before_action :load_owner

  def update
    attributes = params.expect(knowledge_applicability: [ :all_products, :all_connections, product_ids: [], connection_ids: [] ])
    KnowledgeApplicability.transaction do
      @owner.lock!
      mapping = @owner.knowledge_applicability || @owner.build_knowledge_applicability(workspace: Current.workspace)
      previous_mapping = mapping.persisted? ? mapping.audit_snapshot : "inherited"
      mapping.assign_attributes(attributes.slice(:all_products, :all_connections))
      products = selected(Current.workspace.products, attributes[:product_ids], all: mapping.all_products?)
      connections = selected(Current.workspace.intercom_connections, attributes[:connection_ids], all: mapping.all_connections?)
      mapping.save!
      mapping.knowledge_applicability_products.delete_all
      mapping.knowledge_applicability_connections.delete_all
      products.each { |product| mapping.knowledge_applicability_products.create!(workspace: Current.workspace, product:) }
      connections.each { |intercom_connection| mapping.knowledge_applicability_connections.create!(workspace: Current.workspace, intercom_connection:) }
      audit_event("knowledge.applicability_updated", subject: mapping,
        metadata: { previous_mapping:, mapping: mapping.reload.audit_snapshot })
    end
    redirect_to return_path, notice: "Knowledge applicability saved."
  rescue ArgumentError, ActiveRecord::RecordInvalid => error
    redirect_to return_path, alert: error.message
  end

  def destroy
    KnowledgeApplicability.transaction do
      @owner.lock!
      previous_mapping = @owner.knowledge_applicability&.audit_snapshot || "inherited"
      @owner.knowledge_applicability&.destroy!
      audit_event("knowledge.applicability_reset", subject: @owner, metadata: { previous_mapping:, mapping: "inherited" })
    end
    redirect_to return_path, notice: "Knowledge applicability reset to defaults."
  end

  private
    def load_owner
      if params[:knowledge_source_id]
        return head :forbidden unless Current.require_membership!.can_manage_work?
        @owner = Current.workspace.knowledge_sources.find(params[:knowledge_source_id])
      else
        return head :forbidden unless Current.require_membership!.can_configure_integrations?
        @owner = Current.workspace.intercom_connections.find(params[:intercom_connection_id])
      end
    end

    def selected(relation, ids, all:)
      return [] if all
      ids = Array(ids).reject(&:blank?).uniq
      raise ArgumentError, "Select at most 100 items." if ids.size > 100
      raise ArgumentError, "Select at least one item or choose All." if ids.empty?
      relation.find(ids)
    end

    def return_path
      if @owner.is_a?(KnowledgeSource)
        workspace_knowledge_source_path(Current.workspace, @owner)
      else
        workspace_intercom_connections_path(Current.workspace)
      end
    end
end
