class WorkspaceSetupChecklist
  include Rails.application.routes.url_helpers

  Item = Data.define(:name, :state, :detail, :path, :test_path) do
    def initialize(name:, state:, detail:, path:, test_path: nil)
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
      if ENV["NAVISHAI_MEMORY_PENDING"] == "1"
        return Item.new(name: "Memory", state: "skipped", detail: "Memory setup is deferred. Complete the pinned Supermemory first-boot key step, then resume setup.", path: workspace_memory_records_path(@workspace))
      end

      failed = @workspace.memory_index_entries.where(status: %w[failed unknown]).exists?
      state = failed ? "blocked" : @workspace.memory_records.exists? ? "configured" : "skipped"
      Item.new(name: "Memory", state:, detail: failed ? "Indexing needs attention; source records remain saved." : "Memory readiness needs indexed workspace records.", path: workspace_memory_records_path(@workspace))
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
      check = AttachmentScannerCheck.latest_for_current_configuration(@workspace)
      if check.nil?
        Item.new(name: "Attachments", state: "configured", detail: "ClamAV is configured but has not been tested. Files stay quarantined until a scanner returns a clean result.", path:, test_path:)
      elsif check.result == "passed" && check.checked_at >= AttachmentScannerCheck::FRESH_FOR.ago
        Item.new(name: "Attachments", state: "tested", detail: "Synthetic scan passed on #{check.checked_at.to_date}: the clean fixture was reported clean and the EICAR test signature was detected. This proves reachability and classification, not real-malware coverage.", path:, test_path:)
      elsif check.result == "passed"
        Item.new(name: "Attachments", state: "configured", detail: "The last passing synthetic scan is older than 30 days. Test the scanner again.", path:, test_path:)
      elsif check.result == "unavailable"
        Item.new(name: "Attachments", state: "blocked", detail: "The scanner was unreachable or errored on #{check.checked_at.to_date} (#{check.result_code.humanize(capitalize: false)}). Files stay quarantined until a scanner returns a clean result.", path:, test_path:)
      else
        Item.new(name: "Attachments", state: "blocked", detail: "The synthetic scan failed on #{check.checked_at.to_date} (#{check.result_code.humanize(capitalize: false)}). Files stay quarantined until a scanner returns a clean result.", path:, test_path:)
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
