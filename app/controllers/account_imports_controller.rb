class AccountImportsController < ApplicationController
  include WorkspaceAuthorization

  before_action :require_workspace
  before_action :set_context

  rescue_from Current::RoleAccessDenied, with: :forbidden

  def create
    upload = params.require(:file)
    raise AccountDataImport::InvalidImport, "CSV is too large." if upload.size > AccountDataImport::MAX_BYTES

    count = AccountDataImport.import_csv!(workspace: @workspace, membership: @membership, content: upload.read)
    redirect_to workspace_accounts_path(@workspace), notice: "Imported data for #{count} accounts."
  rescue AccountDataImport::InvalidImport, ActionController::ParameterMissing => error
    redirect_to workspace_accounts_path(@workspace), alert: error.message
  end

  def create_api
    raise AccountDataImport::InvalidImport, "API payload is too large." if
      request.content_length.to_i > AccountDataImport::MAX_BYTES
    records = params.require(:records)
    raise AccountDataImport::InvalidImport, "API payload must contain 1 to 500 records." unless records.is_a?(Array)

    count = AccountDataImport.import_api!(
      workspace: @workspace, membership: @membership,
      rows: records.map { |record| record.permit(*AccountDataImport::FIELDS).to_h }
    )
    render json: { imported_accounts: count }, status: :created
  rescue AccountDataImport::InvalidImport, ActionController::ParameterMissing => error
    render json: { error: error.message }, status: :unprocessable_content
  end

  private
    def set_context
      @workspace = Current.require_workspace!
      @membership = Current.require_membership!
    end

    def forbidden
      head :forbidden
    end
end
