require "test_helper"

class WorkspacePortabilityTest < ActiveSupport::TestCase
  test "exports every workspace table without another tenant or user credentials" do
    workspace = workspaces(:acme_support)
    exported_at = Time.zone.parse("2026-08-24 12:00:00")

    assert_difference "AuditEvent.count", 1 do
      @compressed = WorkspacePortability.export(
        workspace:, membership: memberships(:owner_support), exported_at:
      )
    end
    archive = archive_manifest(@compressed)
    expected_tables = ActiveRecord::Base.connection.select_values(<<~SQL.squish)
      SELECT table_name FROM information_schema.columns
      WHERE table_schema = 'public' AND column_name = 'workspace_id'
      ORDER BY table_name
    SQL

    assert_equal WorkspacePortability::FORMAT, archive.fetch("format")
    assert_equal exported_at.iso8601(6), archive.fetch("exported_at")
    assert_equal workspace.runner_key, archive.dig("workspace", "runner_key")
    assert_equal expected_tables, archive.fetch("tables").keys
    archive.fetch("tables").each_value do |rows|
      assert rows.all? { |row| row.fetch("workspace_id") == workspace.id }
    end
    user_rows = archive.fetch("users")
    assert_includes user_rows.map { |user| user.fetch("email_address") }, users(:owner).email_address
    refute user_rows.any? { |user| user.key?("password_digest") }
    refute_includes JSON.generate(archive), users(:owner).password_digest
    refute archive.fetch("tables").fetch("accounts").any? { |row| row.fetch("workspace_id") == workspaces(:beta_support).id }

    audit = AuditEvent.order(:id).last
    assert_equal "workspace.exported", audit.action
    assert_equal users(:owner), audit.actor
    assert_equal expected_tables.size, audit.metadata.fetch("table_count")
    assert_operator audit.metadata.fetch("record_count"), :>, 0
  end

  test "only an owner can export a full workspace" do
    workspace = workspaces(:acme_success)

    assert_raises(Current::RoleAccessDenied) do
      WorkspacePortability.export(workspace:, membership: memberships(:teammate_success))
    end
  end

  test "imports a complete archive into a new workspace with remapped links and fresh keys" do
    source = workspaces(:acme_support)
    source.shared_email_inboxes.create!(
      name: "Support", email_address: "support@example.com", credential_key: "support"
    )
    content = "verified attachment"
    attachment = source.stored_attachments.create!(
      source: :user_upload, uploaded_by_membership: memberships(:owner_support), uploaded_by_user: users(:owner),
      filename: "proof.txt", byte_size: content.bytesize, content_sha256: Digest::SHA256.hexdigest(content),
      detected_content_type: "text/plain", scan_status: :available, scan_result_code: "clean", scanned_at: Time.current
    )
    attachment.file.attach(io: StringIO.new(content), filename: "proof.txt", content_type: "text/plain")
    AccountDataImport.import_api!(workspace: source, membership: memberships(:owner_support), rows: [ {
      source_id: "portable-health-1", source_namespace: "portable.crm", account_name: accounts(:acme).name,
      observed_at: 2.days.ago.iso8601, active_users: 25
    } ])
    AccountDataImport.import_api!(workspace: source, membership: memberships(:owner_support), rows: [ {
      source_id: "portable-health-2", source_namespace: "portable.crm", corrects_source_id: "portable-health-1",
      account_name: accounts(:acme).name, observed_at: 1.day.ago.iso8601, active_users: 30
    } ])
    source_check = OperationalCheck.record!(
      workspace: source, membership: memberships(:owner_support), check_kind: "restore_rehearsal",
      result: "passed", result_code: "round_trip_verified",
      evidence_digest: Digest::SHA256.hexdigest("portable restore evidence"),
      source_commit: "e" * 40, checked_at: 2.hours.ago,
      archive_format: WorkspacePortability::FORMAT, counts: { table: 4, record: 40 }
    )
    source_correction = source.account_health_inputs.find_by!(source_key: "portable-health-2")
    source_signal = accounts(:acme).current_health_assessment.signals.find_by!(signal_key: "customer_inactivity_days")
    source_audit_count = source.audit_events.count
    compressed = WorkspacePortability.export(workspace: source, membership: memberships(:owner_support))

    assert_difference "Workspace.count", 1 do
      @imported = WorkspacePortability.import(
        workspace: source, membership: memberships(:owner_support), archive_io: compressed,
        name: "Restored Support", slug: "restored-support"
      )
    end

    assert_equal source.organization, @imported.organization
    assert_equal "Restored Support", @imported.name
    assert_not_equal source.runner_key, @imported.runner_key
    assert @imported.memberships.find_by(user: users(:owner)).owner?
    assert_equal source.accounts.count, @imported.accounts.count
    assert_equal source.contacts.count, @imported.contacts.count
    assert_equal source.conversations.count, @imported.conversations.count
    assert_equal source.conversation_messages.count, @imported.conversation_messages.count
    assert_equal source_audit_count, @imported.audit_events.where.not(action: %w[workspace.imported memory.index_reconstructed]).count
    assert_not_equal source.shared_email_inboxes.order(:id).first.webhook_key,
      @imported.shared_email_inboxes.order(:id).first.webhook_key
    assert_equal content, @imported.stored_attachments.sole.download_verified!
    assert_equal @imported.id, @imported.source_identities.find_by!(entity_kind: "account").account.workspace_id
    restored_correction = @imported.account_health_inputs.find_by!(source_key: source_correction.source_key)
    assert_equal "portable-health-1", restored_correction.corrects_input.source_key
    assert_not_equal source_correction.id, restored_correction.id
    restored_signal = @imported.account_health_signals.find_by!(
      signal_key: source_signal.signal_key, source_locator: source_signal.source_locator
    )
    restored_signal.evidence_refs.each do |reference|
      table = WorkspacePortability::HEALTH_EVIDENCE_TABLES.fetch(reference.fetch("kind"))
      assert ActiveRecord::Base.connection.select_value(
        "SELECT 1 FROM #{ActiveRecord::Base.connection.quote_table_name(table)} " \
        "WHERE workspace_id = #{@imported.id} AND id = #{Integer(reference.fetch('id'))}"
      )
    end
    restored_check = @imported.operational_checks.find_by!(check_kind: source_check.check_kind)
    assert_equal source_check.evidence_digest, restored_check.evidence_digest
    assert_equal 40, restored_check.record_count
    assert_equal users(:owner), restored_check.recorded_by_user
    assert_equal restored_check.recorded_by_user, restored_check.recorded_by_membership.user
    assert @imported.audit_events.exists?(action: "workspace.imported", actor: users(:owner))
  end

  test "round trips historical schema v1 artifacts and published contract families without rewriting history" do
    source = workspaces(:acme_support)
    historical = create_historical_v1(source)
    archive = WorkspacePortability.export(workspace: source, membership: memberships(:owner_support))

    imported = WorkspacePortability.import(
      workspace: source, membership: memberships(:owner_support), archive_io: archive,
      name: "Historical Restore", slug: "historical-restore"
    )

    restored = imported.crew_artifacts.find_by!(payload_digest: historical.payload_digest)
    assert_equal 1, restored.schema_version
    assert_nil restored.resolution_contract_version
    assert_nil restored.contract_result_state
    assert_empty restored.material_claims
    assert_empty restored.contract_blockers
    assert_equal historical.body, restored.body
    assert_equal ResolutionContractFamily::FAMILIES.keys.sort,
      imported.resolution_contract_families.pluck(:family_key).sort
    assert imported.resolution_contract_families.all? do |family|
      family.current_version && family.current_version.resolution_contract_family_id == family.id
    end
  ensure
    archive&.close!
  end

  test "round trips draft and delivery provenance with remapped artifact and editor links" do
    source = workspaces(:acme_support)
    owner = memberships(:owner_support)
    support_case = create_support_case(workspace: source, membership: owner)
    source.conversation_messages.create!(
      conversation: support_case.conversation, direction: :inbound, author_kind: :contact,
      author_contact: support_case.conversation.contact, body: "Portable source evidence",
      occurred_at: 1.hour.ago
    )
    inbox = source.shared_email_inboxes.create!(
      name: "Portable drafts", email_address: "portable@example.com", credential_key: "portable"
    )
    thread = source.email_threads.create!(
      shared_email_inbox: inbox, conversation: support_case.conversation,
      thread_key: "portable-thread@example.com"
    )
    artifact = create_draft_artifact(
      workspace: source, support_case:, membership: owner,
      body: "Portable generated body", result_state: "needs_human"
    )
    draft = EmailDraftWorkflow.save!(
      workspace: source, support_case:, membership: owner,
      body: artifact.body, expected_lock_version: "new",
      source_crew_artifact_id: artifact.id, adopt_source: true
    )
    draft = EmailDraftWorkflow.save!(
      workspace: source, support_case:, membership: owner,
      body: "Portable human final", expected_lock_version: draft.lock_version.to_s,
      source_crew_artifact_id: artifact.id
    )
    delivery = source.outbound_email_deliveries.create!(
      email_draft: draft, shared_email_inbox: inbox, email_thread: thread,
      conversation: support_case.conversation, actor_membership: owner, actor_user: owner.user,
      idempotency_key: "portable-provenance", message_id: "portable@navishai.local",
      from_address: inbox.email_address, to_address: "customer@example.com",
      subject: "Portable proof", body: draft.body, started_at: Time.current,
      **HumanDraftProvenance.delivery_attributes(draft)
    )
    settle_deferred_constraints
    archive = WorkspacePortability.export(workspace: source, membership: owner)

    imported = WorkspacePortability.import(
      workspace: source, membership: owner, archive_io: archive,
      name: "Provenance Restore", slug: "provenance-restore"
    )

    restored_delivery = imported.outbound_email_deliveries.find_by!(idempotency_key: delivery.idempotency_key)
    restored_draft = restored_delivery.email_draft
    restored_artifact = restored_delivery.source_crew_artifact
    assert_not_equal artifact.id, restored_artifact.id
    assert_equal artifact.body, restored_artifact.body
    assert_equal restored_artifact, restored_draft.source_crew_artifact
    assert_equal delivery.generated_body_digest, restored_delivery.generated_body_digest
    assert_equal "needs_human", restored_delivery.generated_contract_result_state
    assert_equal owner.user.email_address, restored_delivery.human_edited_by_user.email_address
    assert_equal restored_delivery.human_edited_by_user, restored_delivery.human_edited_by_membership.user
    assert_equal delivery.human_edited_at.change(usec: 0), restored_delivery.human_edited_at
    assert_equal "Portable human final", restored_delivery.body
  ensure
    archive&.close!
  end

  test "round trips governed memory without exporting engine-private index state" do
    source = workspaces(:acme_support)
    owner = memberships(:owner_support)
    memory = source.memory_records.create!(
      memory_type: :profile, scope_kind: :account, account: accounts(:acme), topic: "portable-dossier",
      content: "Portable dossier context", authority: :source_record, origin_kind: :system,
      source_reference: "test://portable-dossier", source_digest: Digest::SHA256.hexdigest("Portable dossier context"),
      observed_at: 1.day.ago, valid_from: 1.day.ago, confidence: 1, retention_policy: :indefinite
    )
    entry = source.memory_index_entries.create!(memory_record: memory)
    entry.update!(status: :indexing, attempt_count: 1, last_attempted_at: Time.current)
    entry.update!(
      status: :indexed, external_document_id: "engine-private-dossier-id",
      external_status: "done", indexed_at: Time.current
    )
    archive = WorkspacePortability.export(workspace: source, membership: owner)
    index_row = archive_manifest(archive).fetch("tables").fetch("memory_index_entries")
      .find { |row| row.fetch("memory_record_id") == memory.id }

    assert_equal "pending", index_row.fetch("status")
    assert_equal 0, index_row.fetch("attempt_count")
    assert_nil index_row.fetch("external_document_id")
    assert_nil index_row.fetch("external_status")
    assert_nil index_row.fetch("indexed_at")
    archive.rewind

    imported = WorkspacePortability.import(
      workspace: source, membership: owner, archive_io: archive,
      name: "Memory State Restore", slug: "memory-state-restore"
    )
    restored_memory = imported.memory_records.find_by!(topic: memory.topic)
    restored_entry = restored_memory.memory_index_entry
    assert restored_entry.pending?
    assert_equal 0, restored_entry.attempt_count
    assert_nil restored_entry.external_document_id
    assert_nil restored_entry.external_status
    assert_nil restored_entry.indexed_at
  ensure
    archive&.close!
  end

  test "verifies a full round trip with table and attachment digests, tenant links, and Memory claims" do
    source = workspaces(:acme_support)
    owner = memberships(:owner_support)
    content = "verified archive bytes"
    attachment = source.stored_attachments.create!(
      source: :user_upload, uploaded_by_membership: owner, uploaded_by_user: owner.user,
      filename: "archive-proof.txt", byte_size: content.bytesize,
      content_sha256: Digest::SHA256.hexdigest(content), detected_content_type: "text/plain",
      scan_status: :available, scan_result_code: "clean", scanned_at: Time.current
    )
    attachment.file.attach(io: StringIO.new(content), filename: attachment.filename, content_type: "text/plain")
    support_case = create_support_case(workspace: source, membership: owner)
    memory = source.memory_records.create!(
      memory_type: :semantic, scope_kind: :support_case, support_case:, topic: "archive verification",
      content: "Rebuild this record from PostgreSQL.", authority: :source_record, origin_kind: :system,
      source_reference: "test://archive-verification", source_digest: Digest::SHA256.hexdigest("source"),
      observed_at: 1.day.ago, valid_from: 1.day.ago, confidence: 1, retention_policy: :indefinite
    )
    source.memory_index_entries.create!(
      memory_record: memory, status: :indexed, attempt_count: 1,
      external_document_id: "engine-private-verification-id", external_status: "done",
      last_attempted_at: Time.current, indexed_at: Time.current
    )
    checked_at = Time.zone.parse("2026-08-28 15:00:00 UTC")

    assert_difference -> { ActiveJob::Base.queue_adapter.enqueued_jobs.size }, 1 do
      @verification = WorkspacePortability.verify_round_trip(
        workspace: source, membership: owner, name: "Verified Support", slug: "verified-support",
        source_commit: "a" * 40, checked_at:
      )
    end

    imported = @verification.workspace
    check = @verification.operational_check
    assert_equal source.organization, imported.organization
    assert_not_equal source.id, imported.id
    assert_not_equal source.runner_key, imported.runner_key
    assert imported.memberships.find_by!(user: owner.user).owner?
    assert_equal content, imported.stored_attachments.find_by!(filename: attachment.filename).download_verified!
    restored_entry = imported.memory_records.find_by!(topic: memory.topic).memory_index_entry
    assert restored_entry.indexing?
    assert_equal 1, restored_entry.attempt_count
    assert_nil restored_entry.external_document_id
    assert_equal "passed", check.result
    assert_equal "round_trip_verified", check.result_code
    assert_equal WorkspacePortability::FORMAT, check.archive_format
    assert_equal source, check.workspace
    assert_equal owner.user, check.recorded_by_user
    assert_equal checked_at, check.checked_at
    assert_operator check.table_count, :>, 0
    assert_operator check.record_count, :>, 0
    assert_equal source.stored_attachments.count, check.attachment_count
    assert_equal source.memory_records.count, check.memory_count
    assert_equal owner.user, imported.audit_events.find_by!(action: "workspace.imported").actor
    assert_equal owner.user, imported.audit_events.find_by!(action: "memory.index_reconstructed").actor
    assert_equal 1, imported.audit_events.where(action: "workspace.imported").count
    assert_equal 1, imported.audit_events.where(action: "memory.index_reconstructed").count
    assert_match(/\A[0-9a-f]{64}\z/, check.evidence_digest)
    refute_includes check.attributes.to_json, memory.content
    refute_includes check.attributes.to_json, attachment.filename
    refute imported.accounts.where(id: workspaces(:beta_support).account_ids).exists?
  end

  test "rolls back the verified target and its objects when the success ledger audit fails" do
    source = workspaces(:acme_support)
    owner = memberships(:owner_support)
    2.times do |index|
      create_archive_attachment(
        workspace: source, membership: owner, filename: "ledger-#{index}.txt", content: "ledger bytes #{index}"
      )
    end
    workspace_ids = Workspace.ids
    check_ids = source.operational_check_ids
    storage_before = storage_objects
    source_commit = "f" * 40
    original = AuditEvent.method(:record!)
    success_ledger_failed = false
    replacement = lambda do |**arguments|
      if arguments.fetch(:action) == "operations.check_recorded" && !success_ledger_failed
        success_ledger_failed = true
        raise "success ledger unavailable"
      end
      original.call(**arguments)
    end

    with_replaced_class_method(AuditEvent, :record!, replacement) do
      error = assert_raises(WorkspacePortability::VerificationFailed) do
        WorkspacePortability.verify_round_trip(
          workspace: source, membership: owner, name: "Ledger Failure", slug: "ledger-failure",
          source_commit:
        )
      end
      assert_equal "archive_round_trip_failed", error.result_code
    end

    assert_equal workspace_ids, Workspace.ids
    assert_equal storage_before, storage_objects
    new_checks = source.operational_checks.where.not(id: check_ids)
    assert_equal 1, new_checks.count
    check = new_checks.sole
    assert_equal "failed", check.result
    assert_equal "archive_round_trip_failed", check.result_code
    assert_equal source_commit, check.source_commit
    assert_equal owner.user, check.recorded_by_user
    assert_operator check.table_count, :>, 0
    assert_operator check.record_count, :>, 0
    assert_equal 2, check.attachment_count
    refute source.operational_checks.where(result: "passed", source_commit:).exists?
  end

  test "cleans the first uploaded object when a later attachment upload fails" do
    source = workspaces(:acme_support)
    owner = memberships(:owner_support)
    source_attachments = 2.times.map do |index|
      create_archive_attachment(
        workspace: source, membership: owner, filename: "upload-#{index}.txt", content: "upload bytes #{index}"
      )
    end
    workspace_ids = Workspace.ids
    storage_before = storage_objects
    source_bytes = source_attachments.to_h { |attachment| [ attachment.file.key, attachment.file.download ] }
    original = ActiveStorage::Blob.method(:create_and_upload!)
    upload_count = 0
    replacement = lambda do |**arguments|
      upload_count += 1
      raise IOError, "second target upload failed" if upload_count == 2

      original.call(**arguments)
    end

    with_replaced_class_method(ActiveStorage::Blob, :create_and_upload!, replacement) do
      error = assert_raises(WorkspacePortability::VerificationFailed) do
        WorkspacePortability.verify_round_trip(
          workspace: source, membership: owner, name: "Upload Failure", slug: "upload-failure",
          source_commit: "1" * 40
        )
      end
      assert_equal "archive_round_trip_failed", error.result_code
    end

    assert_equal 2, upload_count
    assert_equal workspace_ids, Workspace.ids
    assert_equal storage_before, storage_objects
    assert_equal source_bytes, source_attachments.to_h { |attachment| [ attachment.file.key, attachment.file.download ] }
    check = source.operational_checks.latest_first.first
    assert_equal "failed", check.result
    assert_equal "archive_round_trip_failed", check.result_code
  end

  test "fails closed and records bounded evidence when Memory reconstruction is uncertain" do
    source = workspaces(:acme_support)
    owner = memberships(:owner_support)
    source.memory_records.create!(
      memory_type: :semantic, scope_kind: :workspace, topic: "uncertain archive reconstruction",
      content: "This record must receive one durable claim.", authority: :source_record, origin_kind: :system,
      source_reference: "test://uncertain-archive", source_digest: Digest::SHA256.hexdigest("uncertain"),
      observed_at: 1.day.ago, valid_from: 1.day.ago, confidence: 1, retention_policy: :indefinite
    )
    singleton = WorkspacePortability.singleton_class
    original = WorkspacePortability.method(:reconstruct_imported_memory!)
    singleton.define_method(:reconstruct_imported_memory!) do |workspace, membership, include_pending:|
      original.call(workspace, membership, include_pending:)
      0
    end

    assert_no_difference "Workspace.count" do
      error = assert_raises(WorkspacePortability::VerificationFailed) do
        WorkspacePortability.verify_round_trip(
          workspace: source, membership: owner, name: "Uncertain Restore", slug: "uncertain-restore",
          source_commit: "b" * 40
        )
      end
      assert_equal "memory_reconstruction_uncertain", error.result_code, error.detail
    end
    check = source.operational_checks.latest_first.first
    assert_equal "failed", check.result
    assert_equal "memory_reconstruction_uncertain", check.result_code
    assert_match(/\A[0-9a-f]{64}\z/, check.evidence_digest)
  ensure
    if singleton && original
      singleton.define_method(:reconstruct_imported_memory!, original)
      singleton.send(:private, :reconstruct_imported_memory!)
    end
  end

  test "fails closed on attachment mismatch without retaining archive content" do
    source = workspaces(:acme_support)
    owner = memberships(:owner_support)
    content = "tampered archive bytes"
    attachment = source.stored_attachments.create!(
      source: :user_upload, uploaded_by_membership: owner, uploaded_by_user: owner.user,
      filename: "tampered.txt", byte_size: content.bytesize,
      content_sha256: Digest::SHA256.hexdigest(content), detected_content_type: "text/plain",
      scan_status: :available, scan_result_code: "clean", scanned_at: Time.current
    )
    attachment.file.attach(io: StringIO.new(content), filename: attachment.filename, content_type: "text/plain")
    attachment.file.blob.service.upload(
      attachment.file.blob.key, StringIO.new("x" * content.bytesize)
    )

    assert_no_difference "Workspace.count" do
      error = assert_raises(WorkspacePortability::VerificationFailed) do
        WorkspacePortability.verify_round_trip(
          workspace: source, membership: owner, name: "Tampered Restore", slug: "tampered-restore",
          source_commit: "c" * 40
        )
      end
      assert_equal "attachment_mismatch", error.result_code
    end
    check = source.operational_checks.latest_first.first
    assert_equal "failed", check.result
    assert_equal "attachment_mismatch", check.result_code
    refute_includes check.attributes.to_json, content
  end

  test "fails closed on unsupported schema, missing verified user, and cross-Organization archive" do
    source = workspaces(:acme_support)
    cases = {
      "unsupported_schema" => ->(archive) { archive["format"] = "navishai-workspace-v999" },
      "missing_user" => ->(archive) { archive.fetch("users").first["email_address"] = "missing@example.com" },
      "cross_organization_archive" => ->(archive) { archive.fetch("organization")["slug"] = "other-org" }
    }

    cases.each_with_index do |(expected_code, mutation), index|
      with_mutated_verification_archive(mutation) do
        assert_verification_failure(
          expected_code, source:, slug: "invalid-archive-#{index}", source_commit: (index + 4).to_s * 40
        )
      end
    end
  end

  test "fails closed on partial import, normalized count and digest drift, and tenant-link failure" do
    source = workspaces(:acme_support)
    stages = {
      "partial_import" => [ :verify_import!, ->(**) { raise WorkspacePortability::VerificationFailed, "partial_import" } ],
      "table_count_mismatch" => [ :verification_generated_row_count, ->(_table, _tables) { 10_000 } ],
      "table_digest_mismatch" => [ :normalize_imported_row, nil ],
      "tenant_isolation_failed" => [ :verify_tenant_links!,
        ->(*) { raise WorkspacePortability::VerificationFailed, "tenant_isolation_failed" } ]
    }

    stages.each_with_index do |(expected_code, (method_name, replacement)), index|
      if method_name == :normalize_imported_row
        original = WorkspacePortability.method(method_name)
        replacement = lambda do |row, **arguments|
          original.call(row, **arguments).merge("created_at" => Time.zone.at(0))
        end
      end
      with_workspace_portability_method(method_name, replacement) do
        assert_verification_failure(
          expected_code, source:, slug: "verification-drift-#{index}", source_commit: %w[a b c d].fetch(index) * 40
        )
      end
    end
  end

  test "round trips configured usage estimates in final immutable shape" do
    source = workspaces(:acme_support)
    owner = memberships(:owner_support)
    approve_scripted_runtime(workspace: source, membership: owner)
    CrewConfiguration.install_defaults!(workspace: source)
    support_case = create_support_case(subject: "Portable usage", workspace: source, membership: owner)
    coordinator = source.agent_profiles.find_by!(role_key: "support_coordinator")
    investigator = source.agent_profiles.find_by!(role_key: "support_investigator")
    run_task = CrewWork.create!(
      workspace: source, membership: owner, scope: support_case, profile: coordinator,
      title: "Portable run usage", input_context: "Use retained facts.",
      expected_output: "Return a bounded result."
    )
    search_task = CrewWork.create!(
      workspace: source, membership: owner, scope: support_case, profile: investigator,
      title: "Portable search usage", input_context: "Use retained facts.",
      expected_output: "Return a bounded result."
    )
    version = UsageRateConfiguration.publish!(
      workspace: source, membership: owner,
      attributes: {
        expected_current_version_id: nil, currency: "USD", source_name: "Portable public rate card",
        input_rate: "2", output_rate: "4", search_rate: "5"
      },
      published_at: Time.zone.parse("2026-08-27 14:00:00")
    )
    run = ExecutionLedger.new(workspace: source).prepare!(
      task: run_task, request_key: "portable-usage-run"
    )
    ingest_execution(source, run, 1, "run.admitted",
      workspace_key: source.runner_key, task_key: run_task.task_key, attempt: run.attempt_number)
    ingest_execution(source, run, 2, "run.started",
      adapter: "scripted", scenario: "portable usage", attempt: run.attempt_number)
    ingest_execution(source, run, 3, "usage.observed", input_units: 100, output_units: 50)
    ingest_execution(source, run, 4, "run.failed", code: "portable_failure", retryable: false)
    run_snapshot = run.reload.usage_cost_snapshot

    response = {
      "protocol_version" => "v1", "workspace_key" => source.runner_key,
      "request_key" => "portable-usage-search", "query" => "public status history",
      "provider_key" => "searxng", "policy_decision" => "allowed", "cost_units" => 200,
      "retrieved_at" => Time.zone.parse("2026-08-27 14:05:00").iso8601(6), "results" => []
    }
    client = Object.new
    client.define_singleton_method(:web_search!) { |**| response }
    search = PublicWebResearch.perform!(
      workspace: source, membership: owner, task: search_task, query: "public status history",
      request_key: "portable-usage-search", client:
    )
    search_snapshot = search.usage_cost_snapshot
    source_run_snapshot = run_snapshot.attributes
    source_search_snapshot = search_snapshot.attributes
    settle_deferred_constraints
    archive = WorkspacePortability.export(workspace: source, membership: owner)

    imported = WorkspacePortability.import(
      workspace: source, membership: owner, archive_io: archive,
      name: "Usage Restore", slug: "usage-restore"
    )

    restored_version = imported.usage_rate_setting.current_version
    restored_run = imported.execution_runs.find_by!(request_key: run.request_key)
    restored_search = imported.public_web_searches.find_by!(request_key: search.request_key)
    restored_run_snapshot = restored_run.usage_cost_snapshot
    restored_search_snapshot = restored_search.usage_cost_snapshot

    assert_not_equal version.id, restored_version.id
    assert_equal version.attributes.except("id", "workspace_id", "usage_rate_setting_id",
      "created_by_membership_id", "created_by_user_id", "created_at", "updated_at"),
      restored_version.attributes.except("id", "workspace_id", "usage_rate_setting_id",
        "created_by_membership_id", "created_by_user_id", "created_at", "updated_at")
    assert_equal owner.user, restored_version.created_by_user
    assert_not_equal owner.id, restored_version.created_by_membership_id
    assert_equal restored_version.created_by_user, restored_version.created_by_membership.user
    assert_equal imported, restored_version.created_by_membership.workspace

    assert_not_equal run.id, restored_run.id
    assert_not_equal search.id, restored_search.id
    assert_equal restored_version, restored_run.usage_rate_version
    assert_equal restored_version, restored_search.usage_rate_version
    assert_equal restored_version, restored_run_snapshot.applied_usage_rate_version
    assert_equal restored_version, restored_search_snapshot.applied_usage_rate_version
    assert_not_equal run_snapshot.id, restored_run_snapshot.id
    assert_not_equal search_snapshot.id, restored_search_snapshot.id
    assert_usage_snapshot_equal(run_snapshot, restored_run_snapshot)
    assert_usage_snapshot_equal(search_snapshot, restored_search_snapshot)
    assert_equal 400, restored_run_snapshot.amount_micros
    assert_equal 1_000, restored_search_snapshot.amount_micros
    assert_equal imported.id, restored_run_snapshot.execution_run.workspace_id
    assert_equal imported.id, restored_search_snapshot.public_web_search.workspace_id
    assert_equal imported.id, restored_run_snapshot.applied_usage_rate_version.workspace_id
    assert_equal source_run_snapshot, run_snapshot.reload.attributes
    assert_equal source_search_snapshot, search_snapshot.reload.attributes
    refute imported.usage_rate_versions.where(workspace_id: workspaces(:beta_support).id).exists?
    refute imported.usage_cost_snapshots.where(workspace_id: workspaces(:beta_support).id).exists?
  ensure
    archive&.close!
  end

  test "rejects an archive for another organization before writing" do
    source = workspaces(:acme_support)
    compressed = WorkspacePortability.export(workspace: source, membership: memberships(:owner_support))
    organization = Organization.create!(name: "Other Org", slug: "other-org")
    workspace = organization.workspaces.create!(name: "Other Support", slug: "other-support")
    membership = workspace.memberships.create!(user: users(:owner), role: :owner)

    assert_no_difference "Workspace.count" do
      assert_raises(WorkspacePortability::InvalidArchive) do
        WorkspacePortability.import(
          workspace:, membership:,
          archive_io: compressed, name: "Wrong Org", slug: "wrong-org"
        )
      end
    end
  end

  test "round trips two incompressible five MiB attachments" do
    source = workspaces(:acme_support)
    contents = 2.times.map { SecureRandom.random_bytes(5.megabytes) }
    contents.each_with_index do |content, index|
      attachment = source.stored_attachments.create!(
        source: :user_upload, uploaded_by_membership: memberships(:owner_support), uploaded_by_user: users(:owner),
        filename: "random-#{index}.bin", byte_size: content.bytesize, content_sha256: Digest::SHA256.hexdigest(content),
        detected_content_type: "application/octet-stream", scan_status: :available, scan_result_code: "clean",
        scanned_at: Time.current
      )
      attachment.file.attach(io: StringIO.new(content), filename: attachment.filename,
        content_type: attachment.detected_content_type)
    end

    archive = WorkspacePortability.export(workspace: source, membership: memberships(:owner_support))
    imported = WorkspacePortability.import(workspace: source, membership: memberships(:owner_support), archive_io: archive,
      name: "Large Restore", slug: "large-restore")

    assert_equal contents.map { |content| Digest::SHA256.hexdigest(content) }.sort,
      imported.stored_attachments.map { |attachment| Digest::SHA256.hexdigest(attachment.download_verified!) }.sort
  ensure
    archive&.close!
  end

  test "rejects a missing attachment object before writing" do
    source = workspaces(:acme_support)
    content = "must exist"
    attachment = source.stored_attachments.create!(
      source: :user_upload, uploaded_by_membership: memberships(:owner_support), uploaded_by_user: users(:owner),
      filename: "required.txt", byte_size: content.bytesize, content_sha256: Digest::SHA256.hexdigest(content),
      detected_content_type: "text/plain", scan_status: :available, scan_result_code: "clean", scanned_at: Time.current
    )
    attachment.file.attach(io: StringIO.new(content), filename: attachment.filename, content_type: "text/plain")
    archive = WorkspacePortability.export(workspace: source, membership: memberships(:owner_support))
    truncated = archive_without_objects(archive)

    assert_no_difference "Workspace.count" do
      assert_raises(WorkspacePortability::InvalidArchive) do
        WorkspacePortability.import(workspace: source, membership: memberships(:owner_support), archive_io: truncated,
          name: "Truncated", slug: "truncated")
      end
    end
  ensure
    archive&.close!
    truncated&.close!
  end

  test "rejects duplicate attachment metadata before writing an object" do
    source = workspaces(:acme_support)
    content = "one object"
    attachment = source.stored_attachments.create!(
      source: :user_upload, uploaded_by_membership: memberships(:owner_support), uploaded_by_user: users(:owner),
      filename: "one.txt", byte_size: content.bytesize, content_sha256: Digest::SHA256.hexdigest(content),
      detected_content_type: "text/plain", scan_status: :available, scan_result_code: "clean", scanned_at: Time.current
    )
    attachment.file.attach(io: StringIO.new(content), filename: attachment.filename, content_type: "text/plain")
    archive = WorkspacePortability.export(workspace: source, membership: memberships(:owner_support))
    duplicate = archive_with_manifest(archive) do |manifest|
      rows = manifest.fetch("tables").fetch("stored_attachments")
      rows << rows.last.dup
    end

    assert_no_difference "Workspace.count" do
      assert_raises(WorkspacePortability::InvalidArchive) do
        WorkspacePortability.import(workspace: source, membership: memberships(:owner_support), archive_io: duplicate,
          name: "Duplicate", slug: "duplicate")
      end
    end
  ensure
    archive&.close!
    duplicate&.close!
  end

  test "round trips intervention decisions and remaps frozen outcome evidence" do
    source = workspaces(:acme_support)
    owner = memberships(:owner_support)
    account = accounts(:acme)
    at = Time.current.change(usec: 0)
    before_assessment = AccountHealth.recalculate!(
      workspace: source, account:, trigger_kind: "human_request", membership: owner, at:
    )
    plan, = create_reviewed_intervention_plan(
      workspace: source, account:, membership: owner, assessment: before_assessment
    )
    intervention = propose_test_intervention(
      workspace: source, account:, membership: owner, assessment: before_assessment,
      artifact: plan, at: at + 1.minute
    )
    CustomerSuccessInterventionWorkflow.approve!(
      workspace: source, membership: owner, intervention:, at: at + 2.minutes
    )
    CustomerSuccessInterventionWorkflow.complete!(
      workspace: source, membership: owner, intervention:, at: at + 3.minutes
    )
    after_assessment = AccountHealth.recalculate!(
      workspace: source, account:, trigger_kind: "human_request", membership: owner,
      at: at + 4.minutes
    )
    source_review = CustomerSuccessInterventionWorkflow.review!(
      workspace: source, membership: owner, intervention:, after_assessment:,
      uncertainty: "The observed change may have other causes.", at: at + 5.minutes
    )
    settle_deferred_constraints
    archive = WorkspacePortability.export(workspace: source, membership: owner)

    imported = WorkspacePortability.import(
      workspace: source, membership: owner, archive_io: archive,
      name: "Intervention Restore", slug: "intervention-restore"
    )

    restored_plan = imported.crew_artifacts.find_by!(payload_digest: plan.payload_digest)
    restored = restored_plan.customer_success_intervention
    restored_review = restored.outcome_review
    assert restored.reviewed?
    assert_not_equal intervention.id, restored.id
    assert_equal intervention.expected_observable_change, restored.expected_observable_change
    assert_equal owner.user.email_address, restored.accountable_membership.user.email_address
    assert_equal owner.user.email_address, restored_review.reviewed_by_membership.user.email_address
    assert_not_equal before_assessment.id, restored_review.before_account_health_assessment_id
    assert_not_equal after_assessment.id, restored_review.after_account_health_assessment_id
    assert_equal restored_review.before_account_health_assessment_id,
      restored_review.before_snapshot.fetch("assessment_id")
    assert_equal restored_review.after_account_health_assessment_id,
      restored_review.after_snapshot.fetch("assessment_id")
    assert_equal restored_review.before_snapshot.fetch("signals").map { |signal| signal.fetch("id") }.sort,
      restored_review.before_account_health_assessment.signals.pluck(:id).sort
    assert_equal restored_review.after_snapshot.fetch("signals").map { |signal| signal.fetch("id") }.sort,
      restored_review.after_account_health_assessment.signals.pluck(:id).sort
    assert_equal source_review.observed_association, restored_review.observed_association
    evidence_locator = restored.supporting_evidence.sole.fetch("locator")
    assert_match(
      %r{\Ahealth://assessments/#{restored_review.before_account_health_assessment_id}/signals/},
      evidence_locator
    )
    refute_equal intervention.supporting_evidence.sole.fetch("locator"), evidence_locator

    settle_deferred_constraints
    connection = ActiveRecord::Base.connection
    connection.select_value(
      "SELECT expire_workspace_content(#{connection.quote(source.id)}, #{connection.quote(at + 1.day)})"
    )
    retained_archive = WorkspacePortability.export(workspace: source, membership: owner)
    retained_import = WorkspacePortability.import(
      workspace: source, membership: owner, archive_io: retained_archive,
      name: "Retained Intervention Restore", slug: "retained-intervention-restore"
    )
    retained_intervention = retained_import.customer_success_interventions.sole
    assert retained_intervention.outcome_review.retention_expired?
    assert_equal "[Expired by retention policy]", retained_intervention.expected_observable_change
    assert_equal(
      "retention-expired://customer-success-interventions/#{retained_intervention.id}/evidence/1",
      retained_intervention.supporting_evidence.sole.fetch("locator")
    )
  ensure
    archive&.close!
    retained_archive&.close!
  end

  private
    def assert_verification_failure(expected_code, source:, slug:, source_commit:)
      before_ids = Workspace.ids
      before_checks = source.operational_checks.count
      error = assert_raises(WorkspacePortability::VerificationFailed) do
        WorkspacePortability.verify_round_trip(
          workspace: source, membership: memberships(:owner_support),
          name: slug.humanize, slug:, source_commit:
        )
      end
      assert_equal expected_code, error.result_code, error.detail
      assert_equal before_ids, Workspace.ids
      assert_equal before_checks + 1, source.operational_checks.count
      check = source.operational_checks.latest_first.first
      assert_equal "failed", check.result
      assert_equal expected_code, check.result_code
      assert_equal source_commit, check.source_commit
      assert_equal WorkspacePortability::FORMAT, check.archive_format
      assert_match(/\A[0-9a-f]{64}\z/, check.evidence_digest)
    end

    def with_mutated_verification_archive(mutation)
      original = WorkspacePortability.method(:parse_archive)
      replacement = lambda do |io|
        archive, files = original.call(io)
        mutation.call(archive)
        [ archive, files ]
      end
      with_workspace_portability_method(:parse_archive, replacement) { yield }
    end

    def with_workspace_portability_method(name, replacement)
      with_replaced_class_method(WorkspacePortability, name, replacement) { yield }
    end

    def with_replaced_class_method(owner, name, replacement)
      singleton = owner.singleton_class
      original = owner.method(name)
      visibility = singleton.private_method_defined?(name) ? :private : :public
      singleton.define_method(name, replacement)
      singleton.send(visibility, name)
      yield
    ensure
      if singleton && original
        singleton.define_method(name, original)
        singleton.send(visibility, name)
      end
    end

    def create_archive_attachment(workspace:, membership:, filename:, content:)
      workspace.stored_attachments.create!(
        source: :user_upload, uploaded_by_membership: membership, uploaded_by_user: membership.user,
        filename:, byte_size: content.bytesize, content_sha256: Digest::SHA256.hexdigest(content),
        detected_content_type: "text/plain", scan_status: :available, scan_result_code: "clean",
        scanned_at: Time.current
      ).tap do |attachment|
        attachment.file.attach(io: StringIO.new(content), filename:, content_type: "text/plain")
      end
    end

    def storage_objects
      root = Pathname(ActiveStorage::Blob.service.root)
      Dir.glob(root.join("**", "*")).select { |path| File.file?(path) }.sort.to_h do |path|
        [ Pathname(path).relative_path_from(root).to_s, Digest::SHA256.file(path).hexdigest ]
      end
    end

    def create_historical_v1(workspace)
      owner = memberships(:owner_support)
      approve_scripted_runtime(workspace:, membership: owner)
      CrewConfiguration.install_defaults!(workspace:)
      ResolutionContractConfiguration.install_defaults!(workspace:)
      settle_deferred_constraints
      support_case = create_support_case
      settle_deferred_constraints
      profile = workspace.agent_profiles.find_by!(role_key: "support_investigator")
      task = CrewWork.create!(
        workspace:, membership: owner, scope: support_case, profile:, title: "Historical investigation",
        input_context: "Use the current case.", expected_output: "Return schema v1 JSON."
      )
      settle_deferred_constraints
      payload = {
        "schema_version" => 1,
        "kind" => "investigation",
        "body" => "The customer reports an expired reset link.",
        "uncertainty" => "The cause is not yet confirmed.",
        "citations" => [ {
          "kind" => "case",
          "locator" => "case://#{support_case.id}",
          "label" => "Support case"
        } ],
        "conflicts" => [],
        "change_requests" => [],
        "review_outcome" => nil,
        "memory_proposals" => []
      }
      run = ExecutionLedger.new(workspace:).prepare!(task:, request_key: "archive:v1:#{task.id}")
      output = JSON.generate(payload)
      artifact = workspace.crew_artifacts.create!(
        crew_task: task, execution_run: run, version_number: 1, schema_version: 1,
        artifact_kind: payload.fetch("kind"), body: payload.fetch("body"),
        uncertainty: payload.fetch("uncertainty"), citations: payload.fetch("citations"),
        conflicts: [], change_requests: [], payload_digest: Digest::SHA256.hexdigest(output)
      )
      settle_deferred_constraints
      artifact
    end

    def settle_deferred_constraints
      connection = ActiveRecord::Base.connection
      connection.execute("SET CONSTRAINTS ALL IMMEDIATE")
      connection.execute("SET CONSTRAINTS ALL DEFERRED")
    end

    def ingest_execution(workspace, run, sequence, event_type, **data)
      event = ExecutionLedger.new(workspace:).ingest!(event: {
        "protocol_version" => "v1", "event_id" => SecureRandom.uuid, "run_id" => run.run_key,
        "sequence" => sequence, "event_type" => event_type,
        "occurred_at" => (Time.zone.parse("2026-08-27 14:00:00") + sequence.seconds).iso8601(6),
        "data" => data.stringify_keys
      })
      settle_deferred_constraints
      event
    end

    def assert_usage_snapshot_equal(source, restored)
      attributes = %w[
        status source currency amount_micros observed_input_units observed_output_units
        observed_search_units calculation_provenance captured_at
      ]
      assert_equal source.attributes.slice(*attributes), restored.attributes.slice(*attributes)
    end

    def archive_manifest(archive)
      archive.rewind
      gzip = Zlib::GzipReader.new(archive)
      manifest = nil
      Gem::Package::TarReader.new(gzip) do |tar|
        manifest = JSON.parse(tar.find { |entry| entry.full_name == "manifest.json" }.read)
      end
      manifest
    end

    def archive_without_objects(archive)
      archive_with_manifest(archive) { |_manifest| }
    end

    def archive_with_manifest(archive)
      output = Tempfile.new([ "truncated", ".tar.gz" ], binmode: true)
      parsed = archive_manifest(archive)
      yield parsed
      manifest = JSON.generate(parsed)
      gzip = Zlib::GzipWriter.new(output)
      begin
        Gem::Package::TarWriter.new(gzip) do |tar|
          tar.add_file_simple("manifest.json", 0o600, manifest.bytesize) { |entry| entry.write(manifest) }
        end
      ensure
        gzip.finish
      end
      output.rewind
      output
    end
end
