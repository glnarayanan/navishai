class WorkspaceSetupChecklist
  include Rails.application.routes.url_helpers

  Item = Data.define(:name, :state, :detail, :path)

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
      Item.new("AI providers", state, state == "ready" ? "A current provider test passed." : "Configure and test a provider before using AI work.", workspace_runtime_installations_path(@workspace))
    end

    def memory
      if ENV["NAVISHAI_MEMORY_PENDING"] == "1"
        return Item.new("Memory", "skipped", "Memory setup is deferred. Complete the pinned Supermemory first-boot key step, then resume setup.", workspace_memory_records_path(@workspace))
      end

      failed = @workspace.memory_index_entries.where(status: %w[failed unknown]).exists?
      state = failed ? "blocked" : @workspace.memory_records.exists? ? "configured" : "skipped"
      Item.new("Memory", state, failed ? "Indexing needs attention; source records remain saved." : "Memory readiness needs indexed workspace records.", workspace_memory_records_path(@workspace))
    end

    def search
      state = @workspace.web_search_provider_key.present? ? "configured" : "skipped"
      Item.new("Public-web search", state, "A saved choice is not a provider readiness check.", edit_workspace_search_settings_path(@workspace))
    end

    def attachments
      scanner = AttachmentScanner.from_environment
      state = scanner.is_a?(AttachmentScanner::Clamd) ? "configured" : "skipped"
      detail = state == "configured" ? "ClamAV is configured but has not been tested. Files stay quarantined until a scanner returns a clean result." : "Configure ClamAV to scan attachments. Until then, files stay quarantined."
      Item.new("Attachments", state, detail, workspace_knowledge_sources_path(@workspace))
    rescue AttachmentScanner::ConfigurationError
      Item.new("Attachments", "invalid", "Attachment scanner settings are invalid. Files stay quarantined until a scanner returns a clean result.", workspace_knowledge_sources_path(@workspace))
    end

    def system_mail
      state = SystemMailConfiguration.status
      detail = state == :configured ? "Deployment SMTP is configured but has not been tested." : state == :invalid ? "Deployment SMTP settings are incomplete or invalid." : "Set deployment SMTP for invitations and reset mail; this is separate from shared-inbox SMTP."
      Item.new("System email", state.to_s, detail, edit_workspace_path(@workspace))
    end

    def connectors
      enabled = WorkspaceConnector.where(workspace: @workspace, enabled: true).exists?
      Item.new("Optional connectors", enabled ? "configured" : "skipped", enabled ? "A connector is enabled; each account still needs its own connection or test." : "Enable only the connectors this workspace needs.", workspace_workspace_connectors_path(@workspace))
    end
end
