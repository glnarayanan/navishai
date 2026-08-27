require "test_helper"

class AccountDossierTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:acme_support)
    @account = accounts(:acme)
    @owner = memberships(:owner_support)
    @now = Time.current.change(usec: 0)
  end

  test "groups current facts conflicts corrections stale and deleted history without tenant leakage" do
    support_case = create_support_case(subject: "Repeated access fault")
    second_case = create_support_case(subject: "Access fault returned")
    tag = CaseWorkflow.create_tag!(workspace: @workspace, membership: @owner, name: "Recurring access")
    CaseWorkflow.tag!(workspace: @workspace, support_case:, membership: @owner, tag:)
    CaseWorkflow.tag!(workspace: @workspace, support_case: second_case, membership: @owner, tag:)
    create_input("renewal_on", date_value: Date.new(2026, 10, 1), observed_at: @now - 2.days)
    create_input("renewal_on", date_value: Date.new(2026, 11, 1), observed_at: @now - 1.day)

    source = create_memory(topic: "support-window", content: "Support ends at 17:00 UTC.")
    correction = MemoryGovernance.propose_correction!(
      workspace: @workspace, membership: @owner, memory_record: source,
      content: "Support ends at 18:00 UTC.", confidence: 1, retention_policy: :indefinite,
      proposed_at: @now - 30.minutes
    ).published_memory_record
    competing = create_memory(topic: "support-window", content: "Support ends at 19:00 UTC.", observed_at: @now - 1.hour)
    stale = create_memory(
      topic: "legacy-plan", content: "Legacy plan was active.", valid_until: @now - 1.hour
    )
    deleted = create_memory(topic: "deleted-note", content: "Removed customer note.")
    MemoryGovernance.delete!(
      workspace: @workspace, membership: @owner, memory_record: deleted, reason: "Customer requested removal"
    )
    create_memory(
      workspace: workspaces(:beta_support), account: accounts(:beta),
      topic: "support-window", content: "Other tenant secret"
    )

    CrewConfiguration.install_defaults!(workspace: @workspace)
    profile = @workspace.agent_profiles.find_by!(role_key: "support_investigator")
    task = CrewWork.create!(
      workspace: @workspace, membership: @owner, scope: support_case, profile:,
      title: "Resolve the recurring access issue", input_context: "Use retained case facts.",
      expected_output: "Return the next human action."
    )

    dossier = AccountDossier.new(workspace: @workspace, account: @account, membership: @owner, now: @now)

    renewal = dossier.fact_groups.find { |group| group.key == "renewal_on" }
    assert renewal.conflicted
    assert_equal Date.new(2026, 11, 1), renewal.effective.date_value
    assert_equal [ Date.new(2026, 11, 1), Date.new(2026, 10, 1) ], renewal.items.map(&:date_value)
    assert_equal [ "Recurring access" ], dossier.recurring_issues.map(&:name)

    support_window = dossier.memory_groups.find { |group| group.label == "support-window" }
    assert support_window.conflicted
    assert_equal correction, support_window.effective
    assert_equal %w[current current superseded], support_window.items.map(&:state)
    assert_equal correction, support_window.items.find { |item| item.record == source }.replaced_by
    assert_equal source, support_window.items.find { |item| item.record == correction }.record.supersedes_memory_record
    assert_includes support_window.items.map(&:record), competing
    assert_equal "stale", dossier.memory_groups.find { |group| group.label == "legacy-plan" }.items.sole.state
    assert_equal "deleted", dossier.memory_groups.find { |group| group.label == "deleted-note" }.items.sole.state
    assert_not_includes dossier.memory_groups.flat_map { |group| group.items.map { |item| item.record.content } }, "Other tenant secret"
    assert_equal task, dossier.next_action.record
  end

  test "includes ambiguous identities tied through candidates and hides memory from viewers" do
    duplicate = contacts(:alice_duplicate)
    matched_identity(duplicate, "duplicate-alice", "alice@example.com")
    ambiguous = SourceIdentityResolver.resolve!(
      workspace: @workspace, entity_kind: :contact, source_namespace: "intercom:primary",
      source_record_type: :contact, source_record_id: "ambiguous-alice",
      keys: { email: "alice@example.com" }
    ).source_identity
    create_memory(topic: "viewer-hidden", content: "Members-only governed context")
    viewer = User.create!(email_address: "dossier-viewer@example.com", password: "password12345", verified_at: @now)
    viewer_membership = @workspace.memberships.create!(user: viewer, role: :viewer)

    owner_dossier = AccountDossier.new(workspace: @workspace, account: @account, membership: @owner, now: @now)
    viewer_dossier = AccountDossier.new(workspace: @workspace, account: @account, membership: viewer_membership, now: @now)

    assert_includes owner_dossier.identities, ambiguous
    assert_equal [ contacts(:alice), duplicate ].map(&:canonical).to_set,
      ambiguous.identity_match_candidates.map { |candidate| candidate.record.canonical }.to_set
    assert owner_dossier.memory_groups.any? { |group| group.label == "viewer-hidden" }
    assert_not viewer_dossier.memory_visible?
    assert_empty viewer_dossier.memory_groups
  end

  test "rebuilds source facts and correction lineage from a Workspace archive" do
    create_input("renewal_on", date_value: Date.new(2026, 12, 1), observed_at: @now - 1.day)
    source = create_memory(topic: "portable-context", content: "Original retained context")
    correction = MemoryGovernance.propose_correction!(
      workspace: @workspace, membership: @owner, memory_record: source,
      content: "Corrected retained context", confidence: 1, retention_policy: :indefinite,
      proposed_at: @now - 30.minutes
    ).published_memory_record
    archive = WorkspacePortability.export(workspace: @workspace, membership: @owner, exported_at: @now)

    imported = WorkspacePortability.import(
      workspace: @workspace, membership: @owner, archive_io: archive,
      name: "Dossier Restore", slug: "dossier-restore", imported_at: @now
    )
    imported_account = imported.accounts.find_by!(name: @account.name)
    imported_membership = imported.memberships.find_by!(user: @owner.user)
    dossier = AccountDossier.new(
      workspace: imported, account: imported_account, membership: imported_membership, now: @now
    )

    renewal = dossier.fact_groups.find { |group| group.key == "renewal_on" }
    memory = dossier.memory_groups.find { |group| group.label == "portable-context" }
    imported_source = memory.items.find { |item| item.record.content == source.content }
    imported_correction = memory.items.find { |item| item.record.content == correction.content }
    assert_equal "api://accounts/acme/renewal_on/#{(@now - 1.day).to_i}", renewal.effective.source_locator
    assert_equal imported_correction.record, imported_source.replaced_by
    assert_equal imported_source.record, imported_correction.record.supersedes_memory_record
    assert_equal "current", imported_correction.state
    assert_equal "superseded", imported_source.state
  ensure
    archive&.close!
  end

  private
    def create_input(key, date_value:, observed_at:)
      source_key = "dossier:#{key}:#{observed_at.to_i}"
      @workspace.account_health_inputs.create!(
        account: @account, input_key: key, value_kind: :date, date_value:,
        source_kind: :api, source_namespace: "dossier_test", source_key:,
        source_digest: Digest::SHA256.hexdigest([ key, "date", date_value.iso8601 ].join("\n")),
        source_locator: "api://accounts/acme/#{key}/#{observed_at.to_i}", observed_at:
      )
    end

    def create_memory(topic:, content:, workspace: @workspace, account: @account, observed_at: @now - 2.hours,
      valid_until: nil)
      workspace.memory_records.create!(
        memory_type: :profile, scope_kind: :account, account:, topic:, content:,
        authority: :source_record, origin_kind: :system, source_reference: "test://#{topic}/#{SecureRandom.hex(4)}",
        source_digest: Digest::SHA256.hexdigest(content), observed_at:, valid_from: observed_at,
        valid_until:, confidence: 0.9, retention_policy: :indefinite
      )
    end

    def matched_identity(contact, source_record_id, email)
      identity = @workspace.source_identities.create!(
        entity_kind: :contact, source_namespace: "manual_import", source_record_type: :contact,
        source_record_id:, status: :matched, contact:, resolution_method: :created, resolved_at: @now
      )
      identity.source_identity_keys.create!(workspace: @workspace, kind: :email, normalized_value: email)
      identity
    end
end
