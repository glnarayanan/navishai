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

  # Runs a scoped synthetic Memory round trip against the configured self-hosted
  # engine. It never falls back to a managed memory host.
  def memory_check
    workspace = Current.require_workspace!
    outcome = MemoryVerificationCheck.run!(
      workspace:, membership: Current.require_membership!,
      sleeper: Rails.env.test? ? ->(_) { } : Kernel.method(:sleep)
    )
    redirect_to workspace_setup_checklist_path(workspace), **memory_check_flash(outcome)
  rescue MemoryVerificationCheck::NotConfigured
    redirect_to workspace_setup_checklist_path(workspace), alert: "Configure self-hosted memory before verifying it. NavishAI will not use a managed memory service."
  rescue MemoryVerificationCheck::SourceCommitUnavailable
    redirect_to workspace_setup_checklist_path(workspace), alert: "Memory tests are unavailable until this deployment has a source version."
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

    def memory_check_flash(outcome)
      case outcome.result
      when "passed"
        { notice: "Memory verification passed: scoped indexing, retrieval, isolation, and removal succeeded for this configuration. Live service proof is separate." }
      when "pending"
        { alert: "Memory verification is not complete (#{outcome.result_code.humanize(capitalize: false)}). Pending is not verified." }
      when "unavailable"
        { alert: "Memory engine unreachable (#{outcome.result_code.humanize(capitalize: false)}). Confirm the self-hosted service; NavishAI will not use a managed host." }
      else
        { alert: "Memory verification failed (#{outcome.result_code.humanize(capitalize: false)}). Failed is not verified." }
      end
    end
end
