class WorkspaceSetupChecklistsController < ApplicationController
  include WorkspaceAuthorization

  before_action :require_workspace
  before_action -> { require_role(:owner, :admin) }

  def show
    @workspace = Current.require_workspace!
    @items = WorkspaceSetupChecklist.new(@workspace).items
  end

  # Runs the synthetic scanner check against the configured daemon and records
  # the outcome. It never changes attachment quarantine state.
  def scanner_check
    workspace = Current.require_workspace!
    outcome = AttachmentScannerCheck.run!(workspace:, membership: Current.require_membership!)
    redirect_to workspace_setup_checklist_path(workspace), **scanner_check_flash(outcome)
  rescue AttachmentScannerCheck::NotConfigured
    redirect_to workspace_setup_checklist_path(workspace), alert: "Configure ClamAV before testing the scanner."
  rescue AttachmentScannerCheck::SourceCommitUnavailable
    redirect_to workspace_setup_checklist_path(workspace), alert: "Scanner tests are unavailable until this deployment has a source version."
  end

  private
    def scanner_check_flash(outcome)
      case outcome.result
      when "passed"
        { notice: "Scanner test passed: the clean fixture was reported clean and the EICAR test signature was detected. Real-malware coverage is not proven." }
      when "unavailable"
        { alert: "Scanner unreachable or errored (#{outcome.result_code.humanize(capitalize: false)}). Files stay quarantined." }
      else
        { alert: "Scanner test failed (#{outcome.result_code.humanize(capitalize: false)}). Files stay quarantined." }
      end
    end
end
