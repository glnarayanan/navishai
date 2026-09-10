class SupportCaseProductsController < ApplicationController
  include WorkspaceAuthorization
  before_action :require_workspace

  def update
    return head :forbidden unless Current.require_membership!.can_manage_work?

    support_case = Current.workspace.support_cases.find(params[:support_case_id])
    ids = Array(params.expect(support_case: [ product_ids: [] ])[:product_ids]).reject(&:blank?).uniq
    return head :unprocessable_content if ids.size > 100
    products = Current.workspace.products.find(ids)
    SupportCase.transaction do
      support_case.lock!
      previous_products = support_case.product_ids.sort.to_json
      support_case.support_case_products.where(workspace: Current.workspace).delete_all
      products.each { |product| support_case.support_case_products.create!(workspace: Current.workspace, product:) }
      audit_event("case.products_updated", subject: support_case,
        metadata: { previous_products:, products: products.map(&:id).sort.to_json })
    end
    redirect_to workspace_support_case_path(Current.workspace, support_case), notice: "Case products updated."
  end
end
