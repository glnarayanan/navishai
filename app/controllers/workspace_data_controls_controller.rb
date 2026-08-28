class WorkspaceDataControlsController < ApplicationController
  include WorkspaceAuthorization

  before_action :require_workspace
  before_action -> { require_role(:owner) }

  def show
    @policy = Current.workspace.workspace_data_policy || Current.workspace.create_workspace_data_policy!
    load_expiry_runs
  end

  def update
    WorkspaceDataGovernance.update_policy!(
      workspace: Current.workspace,
      membership: Current.require_membership!,
      attributes: policy_params
    )
    redirect_to workspace_data_controls_path(Current.workspace), notice: "Data retention policy saved."
  rescue ActiveRecord::RecordInvalid => error
    @policy = error.record
    load_expiry_runs
    render :show, status: :unprocessable_content
  end

  def expire
    WorkspaceContentExpiry.request!(
      workspace: Current.workspace, membership: Current.require_membership!, source: :web
    )
    redirect_to workspace_data_controls_path(Current.workspace), notice: "Content expiry queued."
  rescue ArgumentError => error
    redirect_to workspace_data_controls_path(Current.workspace), alert: error.message
  end

  def expire_audit
    WorkspaceDataGovernance.request_audit_expiry!(
      workspace: Current.workspace, membership: Current.require_membership!, source: :web
    )
    redirect_to workspace_data_controls_path(Current.workspace), notice: "Audit expiry queued."
  rescue ArgumentError => error
    redirect_to workspace_data_controls_path(Current.workspace), alert: error.message
  end

  def export
    archive = WorkspacePortability.export(
      workspace: Current.workspace, membership: Current.require_membership!
    )
    filename = "navishai-workspace-#{Current.workspace.slug}-#{Date.current.iso8601}.tar.gz"
    response.headers["Content-Disposition"] = ActionDispatch::Http::ContentDisposition.format(
      disposition: "attachment", filename:
    )
    response.headers["Content-Type"] = "application/gzip"
    self.response_body = Enumerator.new do |output|
      while (chunk = archive.read(64.kilobytes))
        output << chunk
      end
    ensure
      archive.close!
    end
  end

  def import
    upload = params[:workspace_archive]
    raise WorkspacePortability::InvalidArchive, "Choose a workspace archive." unless upload.respond_to?(:read)

    imported = WorkspacePortability.import(
      workspace: Current.workspace, membership: Current.require_membership!, archive_io: upload,
      name: params[:workspace_name], slug: params[:workspace_slug]
    )
    redirect_to workspace_data_controls_path(imported), notice: "Workspace imported."
  rescue WorkspacePortability::InvalidArchive => error
    @policy = Current.workspace.workspace_data_policy || Current.workspace.create_workspace_data_policy!
    @import_error = error.message
    load_expiry_runs
    render :show, status: :unprocessable_content
  end

  def verify_archive
    source_commit = ENV["NAVISHAI_SOURCE_COMMIT"].to_s
    raise WorkspacePortability::VerificationFailed, "source_commit_unavailable" unless
      source_commit.match?(OperationalCheck::COMMIT_FORMAT)

    checked_at = Time.current
    target_name, target_slug = verification_target_identity(checked_at)
    result = WorkspacePortability.verify_round_trip(
      workspace: Current.workspace, membership: Current.require_membership!,
      name: target_name, slug: target_slug, source_commit:, checked_at:
    )
    redirect_to workspace_data_controls_path(Current.workspace),
      notice: "Archive round trip passed. NavishAI retained #{result.workspace.name} as the new verification target Workspace."
  rescue WorkspacePortability::VerificationFailed => error
    redirect_to workspace_data_controls_path(Current.workspace),
      alert: "Archive round trip failed: #{error.result_code.humanize}. No target Workspace was kept."
  end

  private
    def policy_params
      params.require(:workspace_data_policy).permit(:content_retention_days, :audit_retention_days)
        .to_h.transform_values(&:presence)
    end

    def load_expiry_runs
      @expiry_runs = Current.workspace.workspace_content_expiry_runs.order(created_at: :desc).limit(10)
      @archive_verification = Current.workspace.operational_checks.where(check_kind: "archive_verification")
        .latest_first.first
      @archive_verification_ready = ENV["NAVISHAI_SOURCE_COMMIT"].to_s.match?(OperationalCheck::COMMIT_FORMAT)
    end

    def verification_target_identity(checked_at)
      suffix = "archive-check-#{checked_at.utc.strftime('%Y%m%d%H%M%S')}-#{SecureRandom.hex(3)}"
      slug_prefix = Current.workspace.slug.first(62 - suffix.length).delete_suffix("-")
      [ "#{Current.workspace.name} archive check #{checked_at.utc.strftime('%Y-%m-%d %H:%M UTC')}".first(100),
        "#{slug_prefix}-#{suffix}" ]
    end
end
