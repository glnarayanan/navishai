class AttachmentDownloadsController < ApplicationController
  include WorkspaceAuthorization

  before_action :require_workspace

  def show
    workspace = Current.require_workspace!
    attachment = workspace.stored_attachments.find(params[:id])
    raise ActiveRecord::RecordNotFound unless attachment.available? && attachment.file.attached?

    content = attachment.download_verified!
    AuditEvent.record!(
      action: "attachment.downloaded", source: :web, workspace: workspace,
      actor: Current.user, subject: attachment
    )
    send_data content,
      filename: attachment.filename,
      type: attachment.detected_content_type,
      disposition: :attachment
  rescue ActiveStorage::FileNotFoundError, ActiveStorage::IntegrityError
    raise ActiveRecord::RecordNotFound
  end
end
