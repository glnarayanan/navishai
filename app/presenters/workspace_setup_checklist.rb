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
      failed = @workspace.memory_index_entries.where(status: %w[failed unknown]).exists?
      state = failed ? "blocked" : @workspace.memory_records.exists? ? "configured" : "skipped"
      Item.new("Memory", state, failed ? "Indexing needs attention; source records remain saved." : "Memory readiness needs indexed workspace records.", workspace_memory_records_path(@workspace))
    end

    def search
      state = @workspace.web_search_provider_key.present? ? "configured" : "skipped"
      Item.new("Public-web search", state, "A saved choice is not a provider readiness check.", edit_workspace_search_settings_path(@workspace))
    end

    def attachments
      Item.new("Attachments", "not checked", "Scanner readiness is a deployment check. Files stay quarantined until a scanner returns a clean result.", workspace_knowledge_sources_path(@workspace))
    end

    def system_mail
      Item.new("System email", "not checked", "SMTP is a deployment setting and has not been tested here.", edit_workspace_path(@workspace))
    end

    def connectors
      enabled = WorkspaceConnector.where(workspace: @workspace, enabled: true).exists?
      Item.new("Optional connectors", enabled ? "configured" : "skipped", enabled ? "A connector is enabled; each account still needs its own connection or test." : "Enable only the connectors this workspace needs.", workspace_workspace_connectors_path(@workspace))
    end
end
