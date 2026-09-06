class ProductsController < ApplicationController
  include WorkspaceAuthorization
  before_action :require_workspace
  before_action -> { require_role(:owner, :admin) }

  def index
    @products = Current.workspace.products.order(:name, :id)
  end

  def create
    Product.transaction do
      product = Current.workspace.products.create!(product_params)
      audit_event("product.created", subject: product)
    end
    redirect_to workspace_products_path(Current.workspace), notice: "Product added."
  rescue ActiveRecord::RecordInvalid => error
    @form_error = error.record.errors.full_messages.to_sentence
    index
    render :index, status: :unprocessable_content
  end

  def update
    Product.transaction do
      product = Current.workspace.products.find(params[:id])
      previous_name = product.name
      product.update!(product_params)
      audit_event("product.updated", subject: product, metadata: { previous_name:, name: product.name })
    end
    redirect_to workspace_products_path(Current.workspace), notice: "Product renamed."
  rescue ActiveRecord::RecordInvalid => error
    @form_error = error.record.errors.full_messages.to_sentence
    index
    render :index, status: :unprocessable_content
  end

  private
    def product_params
      params.expect(product: [ :name ])
    end
end
