class WorkspaceSetupChecklist
  include Rails.application.routes.url_helpers

  Item = Data.define(:name, :state, :detail, :path, :test_path, :test_label, :test_confirm) do
    def initialize(name:, state:, detail:, path:, test_path: nil, test_label: nil, test_confirm: nil)
      super
    end
  end

  def initialize(workspace)
    @workspace = workspace
  end

  def items
    [ providers, memory, search, attachments, system_mail, connectors ]
  end

  private

    def providers
      installations = @workspace.runtime_installations
      state = installations.any?(&:runnable?) ? "ready" : installations.exists? ? "configured" : "skipped"
      Item.new(name: "AI providers", state:, detail: state == "ready" ? "A current provider test passed." : "Configure and test a provider before using AI work.", path: workspace_runtime_installations_path(@workspace))
    end

    def memory
      path = workspace_memory_records_path(@workspace)
      if ENV["NAVISHAI_MEMORY_PENDING"] == "1"
        return Item.new(name: "Memory", state: "skipped", detail: "Memory setup is deferred. Complete the pinned Supermemory first-boot key step, then resume setup.", path:)
      end
      unless MemoryVerificationCheck.configured?
        return Item.new(name: "Memory", state: "skipped", detail: "Configure self-hosted memory, then prove scoped indexing and retrieval. NavishAI will not use a managed memory service.", path:)
      end

      test_path = memory_check_workspace_setup_checklist_path(@workspace)
      test_label = "Test memory"
      test_confirm = "Write a unique synthetic Memory record, prove scoped retrieval, then remove it? This does not change customer Memory."
      check = MemoryVerificationCheck.latest_for_current_configuration(@workspace)
      if check.nil?
        Item.new(name: "Memory", state: "configured", detail: "Self-hosted memory is configured but has not been verified. Prove scoped indexing and retrieval before treating Memory as tested.", path:, test_path:, test_label:, test_confirm:)
      elsif check.result == "passed" && check.result_code == "verified" && check.checked_at >= MemoryVerificationCheck::FRESH_FOR.ago
        Item.new(name: "Memory", state: "tested", detail: "Scoped indexing, retrieval, isolation, and removal passed on #{check.checked_at.to_date}. Live service proof is separate from this configuration check.", path:, test_path:, test_label:, test_confirm:)
      elsif check.result == "pending"
        Item.new(name: "Memory", state: "configured", detail: memory_recovery(check), path:, test_path:, test_label:, test_confirm:)
      elsif check.result == "unavailable"
        Item.new(name: "Memory", state: "blocked", detail: memory_recovery(check), path:, test_path:, test_label:, test_confirm:)
      else
        Item.new(name: "Memory", state: "blocked", detail: memory_recovery(check), path:, test_path:, test_label:, test_confirm:)
      end
    end

    def memory_recovery(check)
      case check.result_code
      when "indexing_pending"
        "Indexing is still in progress (#{check.checked_at.to_date}). Wait or test again. Pending is not verified."
      when "cleanup_pending"
        "Synthetic retrieval passed, but removal is still pending (#{check.checked_at.to_date}). Test again to finish cleanup. Pending is not verified."
      when "authentication_failure"
        "Memory engine rejected authentication on #{check.checked_at.to_date}. Replace the self-hosted API key. NavishAI will not fall back to a managed host."
      when "memory_unavailable"
        "Memory engine was unreachable on #{check.checked_at.to_date}. Confirm the self-hosted address and that the service is running."
      when "retrieval_mismatch"
        "The engine did not return the synthetic record for this Workspace on #{check.checked_at.to_date}."
      when "scope_failure"
        "The synthetic record was visible outside this Workspace on #{check.checked_at.to_date}. Stop using this engine until isolation is fixed."
      else
        "Memory verification failed on #{check.checked_at.to_date} (#{check.result_code.humanize(capitalize: false)}). Failed is not verified."
      end
    end

    def search
      state = @workspace.web_search_provider_key.present? ? "configured" : "skipped"
      Item.new(name: "Public-web search", state:, detail: "A saved choice is not a provider readiness check.", path: edit_workspace_search_settings_path(@workspace))
    end

    def attachments
      path = workspace_knowledge_sources_path(@workspace)
      scanner = AttachmentScanner.from_environment
      unless scanner.is_a?(AttachmentScanner::Clamd)
        return Item.new(name: "Attachments", state: "skipped", detail: "Configure ClamAV to scan attachments. Until then, files stay quarantined.", path:)
      end

      test_path = scanner_check_workspace_setup_checklist_path(@workspace)
      test_label = "Test scanner"
      test_confirm = "Send a clean fixture and the EICAR test signature to the configured ClamAV daemon? No attachment changes state."
      check = AttachmentScannerCheck.latest_for_current_configuration(@workspace)
      if check.nil?
        Item.new(name: "Attachments", state: "configured", detail: "ClamAV is configured but has not been tested. Files stay quarantined until a scanner returns a clean result.", path:, test_path:, test_label:, test_confirm:)
      elsif check.result == "passed" && check.checked_at >= AttachmentScannerCheck::FRESH_FOR.ago
        Item.new(name: "Attachments", state: "tested", detail: "Synthetic scan passed on #{check.checked_at.to_date}: the clean fixture was reported clean and the EICAR test signature was detected. This proves reachability and classification, not real-malware coverage.", path:, test_path:, test_label:, test_confirm:)
      elsif check.result == "passed"
        Item.new(name: "Attachments", state: "configured", detail: "The last passing synthetic scan is older than 30 days. Test the scanner again.", path:, test_path:, test_label:, test_confirm:)
      elsif check.result == "unavailable"
        Item.new(name: "Attachments", state: "blocked", detail: "The scanner was unreachable or errored on #{check.checked_at.to_date} (#{check.result_code.humanize(capitalize: false)}). Files stay quarantined until a scanner returns a clean result.", path:, test_path:, test_label:, test_confirm:)
      else
        Item.new(name: "Attachments", state: "blocked", detail: "The synthetic scan failed on #{check.checked_at.to_date} (#{check.result_code.humanize(capitalize: false)}). Files stay quarantined until a scanner returns a clean result.", path:, test_path:, test_label:, test_confirm:)
      end
    rescue AttachmentScanner::ConfigurationError
      Item.new(name: "Attachments", state: "invalid", detail: "Attachment scanner settings are invalid. Files stay quarantined until a scanner returns a clean result.", path:)
    end

    def system_mail
      state = SystemMailConfiguration.status
      detail = state == :configured ? "Deployment SMTP is configured but has not been tested." : state == :invalid ? "Deployment SMTP settings are incomplete or invalid." : "Set deployment SMTP for invitations and reset mail; this is separate from shared-inbox SMTP."
      Item.new(name: "System email", state: state.to_s, detail:, path: edit_workspace_path(@workspace))
    end

    def connectors
      enabled = WorkspaceConnector.where(workspace: @workspace, enabled: true).exists?
      Item.new(name: "Optional connectors", state: enabled ? "configured" : "skipped", detail: enabled ? "A connector is enabled; each account still needs its own connection or test." : "Enable only the connectors this workspace needs.", path: workspace_workspace_connectors_path(@workspace))
    end
end
