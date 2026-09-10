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

  test "personal runtime and completed execution round trip with fresh disconnected identity" do
    workspace = workspaces(:acme_support)
    owner = memberships(:owner_support)
    runtime = approve_scripted_runtime(workspace:, membership: owner)
    account = PersonalProviderAccount.create!(workspace:, membership: owner, state: "connected")
    runtime.update!(personal_provider_account: account)
    CrewConfiguration.install_defaults!(workspace:)
    ResolutionContractConfiguration.install_defaults!(workspace:)
    profile = workspace.agent_profiles.find_by!(role_key: "support_investigator")
    support_case = create_support_case
    message = add_inbound_message(support_case)
    task = CrewWork.create!(workspace:, membership: owner, scope: support_case, profile:,
      title: "Personal investigation", input_context: "Review the case.", expected_output: "Return evidence.")
    run = ExecutionLedger.new(workspace:).prepare!(task:, request_key: "personal-archive", membership: owner, personal_account: account)
    locator = "conversation://#{support_case.conversation_id}/messages/#{message.id}"
    output = JSON.generate(schema_version: 2, kind: "investigation", body: "The customer reports a problem.",
      uncertainty: "The cause is unknown.", conflicts: [], change_requests: [], review_outcome: nil, memory_proposals: [],
      citations: [ { kind: "conversation", locator:, label: "Customer report" } ], required_facts: [ "customer_report" ],
      material_claims: [ { key: "customer_report", category: "customer_account_fact", text: "The customer reports a problem.",
        state: "supported", evidence: [ { kind: "conversation", locator: } ] } ], proposed_actions: [],
      policy_checks: ResolutionContractVersion::REVIEW_CHECKS.keys.sort.map { |check| { check:, status: "passed" } })
    [
      [ "run.admitted", { "workspace_key" => workspace.runner_key, "task_key" => task.task_key, "attempt" => 1 } ],
      [ "run.started", { "adapter" => "scripted", "scenario" => "success", "attempt" => 1 } ],
      [ "output.produced", { "text" => output } ],
      [ "run.completed", { "outcome" => "completed" } ]
    ].each_with_index do |(event_type, data), index|
      ExecutionLedger.new(workspace:).ingest!(event: {
        "protocol_version" => "v1", "event_id" => SecureRandom.uuid, "run_id" => run.run_key,
        "sequence" => index + 1, "event_type" => event_type, "occurred_at" => Time.current.iso8601(6), "data" => data
      })
      ActiveRecord::Base.connection.execute("SET CONSTRAINTS ALL IMMEDIATE")
      ActiveRecord::Base.connection.execute("SET CONSTRAINTS ALL DEFERRED")
    end
    ActiveRecord::Base.connection.execute("SET CONSTRAINTS ALL IMMEDIATE")
    ActiveRecord::Base.connection.execute("SET CONSTRAINTS ALL DEFERRED")

    result = WorkspacePortability.verify_round_trip(workspace:, membership: owner,
      name: "Personal account restore", slug: "personal-account-restore", source_commit: "a" * 40)
    imported = result.workspace
    restored_account = PersonalProviderAccount.find_by!(workspace: imported)
    restored_run = imported.execution_runs.find_by!(request_key: run.request_key)
    assert_not_equal account.account_key, restored_account.account_key
    assert restored_account.disconnected?
    assert_not restored_account.runtime_installation.approved?
    assert_equal "missing", restored_account.runtime_installation.health_status
    assert_equal restored_account.account_key, restored_run.selected_personal_account_key
    assert_equal restored_account.membership_id, restored_run.requested_by_membership_id
    assert_equal restored_account.runtime_installation.id, restored_run.runtime_installation_id
    assert restored_run.completed?
    assert account.reload.connected?
    assert runtime.reload.approved?
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
