require "test_helper"

class WorkspaceConnectionPortabilityTest < ActiveSupport::TestCase
  test "archives disconnect Workspace credentials and exclude all personal OAuth state" do
    workspace = workspaces(:acme_support)
    connector = WorkspaceConnector.create!(workspace:, provider: "notion", enabled: true, service_token: "workspace-secret")
    IntegrationUserConnection.create!(workspace:, workspace_connector: connector,
      membership: memberships(:owner_support), remote_user_id: "private-user", remote_workspace_id: "private-workspace", access_token: "personal-secret")
    session = users(:owner).sessions.create!(expires_at: 1.day.from_now, authentication_method: "local")
    IntegrationOauthAttempt.issue!(connector:, membership: memberships(:owner_support), session:)
    archive = WorkspacePortability.export(workspace:, membership: memberships(:owner_support))
    manifest = manifest_from(archive)
    assert_empty manifest.dig("tables", "integration_user_connections")
    assert_empty manifest.dig("tables", "integration_oauth_attempts")
    archived = manifest.dig("tables", "workspace_connectors").first
    assert_nil archived["service_token"]
    assert_equal false, archived["enabled"]
    refute_includes JSON.generate(manifest), "personal-secret"
    refute_includes JSON.generate(manifest), "workspace-secret"
    refute_includes JSON.generate(manifest), "private-user"
    imported = WorkspacePortability.import(workspace:, membership: memberships(:owner_support), archive_io: archive,
      name: "Disconnected import", slug: "disconnected-import")
    assert_not WorkspaceConnector.find_by!(workspace: imported).enabled?
    assert_empty IntegrationUserConnection.where(workspace: imported)
  ensure
    archive&.close!
  end

  test "import validation rejects forged archive credentials" do
    workspace = workspaces(:acme_support)
    WorkspaceConnector.create!(workspace:, provider: "notion", enabled: true, service_token: "secret")
    archive = WorkspacePortability.export(workspace:, membership: memberships(:owner_support))
    manifest = manifest_from(archive)
    manifest.dig("tables", "workspace_connectors").first["service_token"] = "forged-secret"
    assert_raises(WorkspacePortability::InvalidArchive) do
      WorkspacePortability.send(:validate_archive!, manifest, workspace.organization)
    end
  ensure
    archive&.close!
  end

  private
    def manifest_from(archive)
      archive.rewind
      gzip = Zlib::GzipReader.new(archive)
      manifest = nil
      Gem::Package::TarReader.new(gzip) do |tar|
        manifest = JSON.parse(tar.find { |entry| entry.full_name == "manifest.json" }.read)
      end
      manifest
    ensure
      archive.rewind
    end
end
